$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bootstrapScript = Join-Path $repositoryRoot 'src\persistence\bootstrap.ps1'
$runtimeManifestModule = Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1'
$kernelObjectsModule = Join-Path $repositoryRoot 'src\persistence\modules\KernelObjects.psm1'
$powershellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $bootstrapScript -PathType Leaf)) {
    throw "Bootstrap script is missing: $bootstrapScript"
}
if (-not (Test-Path -LiteralPath $runtimeManifestModule -PathType Leaf)) {
    throw "Runtime manifest module is missing: $runtimeManifestModule"
}
if (-not (Test-Path -LiteralPath $kernelObjectsModule -PathType Leaf)) {
    throw "Kernel object module is missing: $kernelObjectsModule"
}
Import-Module $runtimeManifestModule -Force
Import-Module $kernelObjectsModule -Force

function Assert-CcodExactEqual($Expected, $Actual, [string]$Message) {
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "ASSERT_EXACT: $Message expected=[$Expected] actual=[$Actual]"
    }
}

function New-CcodBootstrapToken {
    return ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
}

function New-CcodTestSupervisorScript {
    param([string]$Kind, [string]$MarkerPath)

    $markerLine = if ([string]::IsNullOrWhiteSpace($MarkerPath)) {
        ''
    } else {
        "[IO.File]::WriteAllText('$MarkerPath','started')"
    }
    switch ($Kind) {
        'Ready' {
            return @"
param([string]`$ReadyToken)
$markerLine
`$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
`$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
`$name="Local\CodexControlOtherDevices.Ready.`$sid.`$session.`$ReadyToken"
`$event=[Threading.EventWaitHandle]::OpenExisting(`$name)
`$event.Set() | Out-Null
Start-Sleep -Milliseconds 200
exit 0
"@
        }
        'ExitEarly' {
            return @"
param([string]`$ReadyToken)
$markerLine
exit 7
"@
        }
        'Timeout' {
            return @"
param([string]`$ReadyToken)
$markerLine
Start-Sleep -Seconds 60
exit 0
"@
        }
        'ExitLaterNonzero' {
            return @"
param([string]`$ReadyToken)
$markerLine
`$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
`$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
`$name="Local\CodexControlOtherDevices.Ready.`$sid.`$session.`$ReadyToken"
`$event=[Threading.EventWaitHandle]::OpenExisting(`$name)
`$event.Set() | Out-Null
Start-Sleep -Milliseconds 300
exit 9
"@
        }
        'ReadyLongLived' {
            return @"
param([string]`$ReadyToken)
[IO.File]::WriteAllText('$MarkerPath',[string]`$PID)
`$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
`$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
`$name="Local\CodexControlOtherDevices.Ready.`$sid.`$session.`$ReadyToken"
`$event=[Threading.EventWaitHandle]::OpenExisting(`$name)
`$event.Set() | Out-Null
Start-Sleep -Seconds 60
exit 0
"@
        }
        default { throw "Unknown fake supervisor kind: $Kind" }
    }
}

function New-CcodBootstrapFixture {
    param([string]$Root)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'logs') -Force | Out-Null
    return $Root
}

function Add-CcodTestRuntime {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SupervisorScript,
        [AllowNull()][string]$RuntimeId,
        [bool]$IncludeFenceModules = $true,
        [bool]$FailLifecycleRelease = $false
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
        $runtimeDirectory = Join-Path $Root ('runtime\pending-' + [guid]::NewGuid().ToString('N'))
    } else {
        $runtimeDirectory = Join-Path $Root "runtime\$RuntimeId"
    }
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    $supervisorDirectory = Join-Path $runtimeDirectory 'src\persistence'
    New-Item -ItemType Directory -Path $supervisorDirectory -Force | Out-Null
    $supervisorPath = Join-Path $supervisorDirectory 'Supervisor.ps1'
    [IO.File]::WriteAllText($supervisorPath, $SupervisorScript, [Text.UTF8Encoding]::new($false))
    $kernelDirectory = Join-Path $runtimeDirectory 'src\persistence\modules'
    New-Item -ItemType Directory -Path $kernelDirectory -Force | Out-Null
    $kernelPath = Join-Path $kernelDirectory 'KernelObjects.psm1'
    [IO.File]::Copy($kernelObjectsModule, $kernelPath, $true)
    if ($IncludeFenceModules) {
        foreach ($moduleName in @('PersistenceIO.psm1','LifecycleEpoch.psm1','RuntimeManifest.psm1')) {
            [IO.File]::Copy((Join-Path $repositoryRoot ('src\persistence\modules\' + $moduleName)), (Join-Path $kernelDirectory $moduleName), $true)
        }
        if ($FailLifecycleRelease) {
            [IO.File]::AppendAllText((Join-Path $kernelDirectory 'LifecycleEpoch.psm1'), @'

function Exit-CcodLifecycleOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ownership, [hashtable]$Adapters)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new('injected lifecycle release failure'),
        'CCOD_LIFECYCLE_RELEASE_FAILED',
        [Management.Automation.ErrorCategory]::CloseError,
        $Ownership)
}
'@, [Text.UTF8Encoding]::new($false))
        }
    }
    $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtimeDirectory -ProjectVersion '0.0.0-bootstrap-test'
    if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
        $RuntimeId = $manifest.runtimeId
        $targetDirectory = Join-Path $Root "runtime\$RuntimeId"
        if ($targetDirectory -cne $runtimeDirectory) {
            [IO.Directory]::Move($runtimeDirectory, $targetDirectory)
            $runtimeDirectory = $targetDirectory
            $supervisorPath = Join-Path $runtimeDirectory 'src\persistence\Supervisor.ps1'
            $kernelPath = Join-Path $runtimeDirectory 'src\persistence\modules\KernelObjects.psm1'
        }
    } else {
        $manifest.runtimeId = $RuntimeId
    }
    [IO.File]::WriteAllText(
        (Join-Path $runtimeDirectory 'manifest.json'),
        ($manifest | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
    return $RuntimeId
}

function Set-CcodTestActivePointer {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ActiveRuntime,
        [AllowNull()][string]$PreviousRuntime,
        [int]$SchemaVersion = 1,
        [UInt64]$Generation = 1
    )

    $pointer = [ordered]@{
        schemaVersion = $SchemaVersion
        activeRuntime = $ActiveRuntime
        previousRuntime = $PreviousRuntime
    }
    if ($SchemaVersion -eq 2) { $pointer.generation = $Generation }
    $pointer.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText(
        (Join-Path $Root 'active.json'),
        ($pointer | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-CcodTestActivePointer {
    param([Parameter(Mandatory)][string]$Root)

    return (Get-Content -LiteralPath (Join-Path $Root 'active.json') -Raw | ConvertFrom-Json)
}

function Invoke-CcodBootstrapUnderTest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ReadyToken,
        [int]$ReadyTimeoutSeconds = 3
    )

    $output = & $powershellExecutable -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript `
        -InstallRoot $Root -ReadyToken $ReadyToken -ReadyTimeoutSeconds $ReadyTimeoutSeconds 2>&1
    $exitCode = [int]$LASTEXITCODE
    return $exitCode
}

function Invoke-CcodBootstrapTimed {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ReadyToken,
        [int]$TimeoutMilliseconds = 4000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powershellExecutable
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -ReadyToken {2} -ReadyTimeoutSeconds 3' -f $bootstrapScript,$Root,$ReadyToken
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $exited = $process.WaitForExit($TimeoutMilliseconds)
        if (-not $exited) {
            $process.Kill()
            $process.WaitForExit()
        }
        return [pscustomobject][ordered]@{
            TimedOut = -not $exited
            ExitCode = if ($exited) { [int]$process.ExitCode } else { $null }
            ElapsedMilliseconds = [long]$stopwatch.ElapsedMilliseconds
        }
    } finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
}

$results = @()

$results += Invoke-CcodTest 'selects previous runtime after active exits before ready and swaps pointer' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 0 $exitCode 'previous fallback succeeds'
        Assert-CcodTrue (Test-Path -LiteralPath $activeMarker) 'active runtime was attempted first'
        Assert-CcodTrue (Test-Path -LiteralPath $previousMarker) 'previous runtime was then launched'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'previous becomes active after ready'
        Assert-CcodExactEqual $activeId $pointer.previousRuntime 'old active is retained for rollback'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'keeps a ready active runtime and does not rewrite the pointer' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $activeMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $null

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 0 $exitCode 'healthy active runtime succeeds'
        Assert-CcodTrue (Test-Path -LiteralPath $activeMarker) 'active supervisor was launched'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $activeId $pointer.activeRuntime 'active pointer is unchanged'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'launches a schema-two active pointer without downgrading its generation' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath (Join-Path $root 'schema2.started'))
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $null -SchemaVersion 2 -Generation 9
        Assert-CcodExactEqual 0 (Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken (New-CcodBootstrapToken)) 'schema-two active pointer launches'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual 2 $pointer.schemaVersion 'healthy schema-two pointer is never downgraded'
        Assert-CcodExactEqual ([UInt64]9) ([UInt64]$pointer.generation) 'healthy schema-two generation remains exact'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

$results += Invoke-CcodTest 'launches a healthy legacy active runtime without requiring fallback fence modules' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath (Join-Path $root 'legacy.started')) -IncludeFenceModules $false
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $null -SchemaVersion 1
        Assert-CcodExactEqual 0 (Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken (New-CcodBootstrapToken)) 'healthy legacy active runtime launches without pointer mutation'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual 1 $pointer.schemaVersion 'healthy legacy active pointer remains unchanged'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

$results += Invoke-CcodTest 'preserves schema-two generation when fallback promotes the previous runtime' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath (Join-Path $root 'schema2-active.started'))
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath (Join-Path $root 'schema2-previous.started'))
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId -SchemaVersion 2 -Generation 9
        Assert-CcodExactEqual 0 (Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken (New-CcodBootstrapToken)) 'schema-two fallback launches verified previous runtime'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual 2 $pointer.schemaVersion 'fallback retains schema two'
        Assert-CcodExactEqual ([UInt64]10) ([UInt64]$pointer.generation) 'fallback increments generation rather than discarding it'
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'fallback commits the ready previous runtime'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

$results += Invoke-CcodTest 'fails promptly when fallback lifecycle ownership cannot be released' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    $supervisorPid = $null
    $lease = $null
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath (Join-Path $root 'release-active.started'))
        $pidPath = Join-Path $root 'release-previous.pid'
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ReadyLongLived' -MarkerPath $pidPath) -FailLifecycleRelease $true
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId -SchemaVersion 2 -Generation 9

        $run = Invoke-CcodBootstrapTimed -Root $root -ReadyToken (New-CcodBootstrapToken)
        if ([IO.File]::Exists($pidPath)) { $supervisorPid = [int][IO.File]::ReadAllText($pidPath) }
        Assert-CcodExactEqual $false $run.TimedOut 'release failure exits instead of waiting for the ready long-lived Supervisor'
        Assert-CcodExactEqual 1 $run.ExitCode 'release failure is a stable nonzero bootstrap outcome'
        Assert-CcodTrue ($run.ElapsedMilliseconds -lt 4000) 'release failure returns within the bounded prompt-exit window'
        $log = [IO.File]::ReadAllText((Join-Path $root 'logs\bootstrap.log'))
        Assert-CcodTrue ($log.Contains('CCOD_BOOTSTRAP_FENCE_RELEASE_FAILED')) 'release failure is normalized to the stable bootstrap code'
        Assert-CcodTrue (-not $log.Contains('signaled ready; active pointer switched')) 'release failure never logs successful fallback readiness'

        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $lease = Enter-CcodMutex -Kind AccountTransition -UserSid $sid -TimeoutMilliseconds 1000
        Assert-CcodExactEqual 'Acquired' $lease.Outcome 'bootstrap exit lets OS cleanup release any recursive mutex ownership'
    } finally {
        if ($null -ne $lease -and $lease.Outcome -ceq 'Acquired' -and -not $lease.Released) { Exit-CcodMutex -Lease $lease | Out-Null }
        if ($null -ne $supervisorPid) {
            $leftover = Get-Process -Id $supervisorPid -ErrorAction SilentlyContinue
            if ($null -ne $leftover) { try { $leftover.Kill(); $leftover.WaitForExit(2000) | Out-Null } finally { $leftover.Dispose() } }
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'does not launch a supervisor while the account transition lease is held' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    $lease = $null
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $marker = Join-Path $root 'blocked.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $marker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $lease = Enter-CcodMutex -Kind AccountTransition -UserSid $sid -TimeoutMilliseconds 1000
        Assert-CcodExactEqual 'Acquired' $lease.Outcome 'test process owns the account transition lease'
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken (New-CcodBootstrapToken) -ReadyTimeoutSeconds 1
        Assert-CcodTrue ($exitCode -ne 0) 'bootstrap reports a busy launch gate without starting a second supervisor'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $marker)) 'busy launch gate prevents the supervisor child from starting'
    } finally {
        if ($null -ne $lease -and $lease.Outcome -ceq 'Acquired') { Exit-CcodMutex -Lease $lease | Out-Null }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'fails and keeps the pointer when both runtimes exit before ready' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath (Join-Path $root 'active.started'))
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath (Join-Path $root 'previous.started'))
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodTrue ($exitCode -ne 0) 'both-invalid bootstrap must fail closed'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $activeId $pointer.activeRuntime 'failed bootstrap never rewrites active'
        Assert-CcodExactEqual $previousId $pointer.previousRuntime 'failed bootstrap never rewrites previous'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'falls back after a ready timeout and stops the exact hung child' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Timeout' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token -ReadyTimeoutSeconds 2
        Assert-CcodExactEqual 0 $exitCode 'timeout falls back to previous'
        Assert-CcodTrue (Test-Path -LiteralPath $activeMarker) 'hung active was launched'
        Assert-CcodTrue (Test-Path -LiteralPath $previousMarker) 'previous was launched after timeout'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'timeout fallback swaps pointer'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'invalid active manifest falls back to a verified previous runtime' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        [IO.File]::WriteAllText(
            (Join-Path $root "runtime\$activeId\Supervisor.ps1"),
            "param([string]`$ReadyToken)`ncorrupt",
            [Text.UTF8Encoding]::new($false)
        )
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 0 $exitCode 'invalid active manifest falls back'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $activeMarker)) 'corrupt active runtime is never executed'
        Assert-CcodTrue (Test-Path -LiteralPath $previousMarker) 'verified previous is launched'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'fallback pointer is swapped'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'rejects a pre-existing stale ready event before launching any supervisor' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    $handle = $null
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $name = "Local\CodexControlOtherDevices.Ready.$sid.$session.$token"
        $created = $false
        $handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name, [ref]$created)
        Assert-CcodTrue $created 'stale-event fixture must create the named event'
        $handle.Set() | Out-Null

        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodTrue ($exitCode -ne 0) 'pre-existing ready event is fail closed'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $activeMarker)) 'stale event must not launch active'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $previousMarker)) 'stale event must not launch previous'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $activeId $pointer.activeRuntime 'stale event leaves pointer unchanged'
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'propagates a nonzero exit after the supervisor signals ready' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitLaterNonzero' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 9 $exitCode 'later abnormal supervisor exit is propagated'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'ready pointer swap still commits before abnormal exit'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'bootstrap contains no Codex process, package, or task mutation commands' {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$tokens, [ref]$parseErrors)
    Assert-CcodExactEqual 0 @($parseErrors).Count 'bootstrap parses before command audit'
    $forbidden = @(
        'Get-Process', 'Stop-Process', 'Get-AppxPackage', 'Get-CimInstance', 'Get-WmiObject',
        'Register-WmiEvent', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'schtasks',
        'Register-ObjectEvent', 'Invoke-WebRequest', 'Invoke-RestMethod', 'node'
    )
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ })
    foreach ($name in $commands) {
        Assert-CcodTrue ($forbidden -cnotcontains $name) "bootstrap cannot reach $name"
    }
}


$results += Invoke-CcodTest 'launches the supervisor child with an explicit STA apartment' {
    $source = Get-Content -LiteralPath $bootstrapScript -Raw
    Assert-CcodTrue ($source.Contains('-STA -File')) 'bootstrap supervisor launch arguments include -STA before -File'
    Assert-CcodTrue ($source.Contains('-NoProfile -ExecutionPolicy Bypass -STA -File')) 'bootstrap uses the exact STA launch argument prefix'
    Assert-CcodTrue (-not $source.Contains('-NoProfile -ExecutionPolicy Bypass -File "')) 'bootstrap no longer launches the supervisor without -STA'
}


$results += Invoke-CcodTest 'defaults InstallRoot to the bootstrap script directory for task launches' {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$tokens, [ref]$parseErrors)
    Assert-CcodExactEqual 0 @($parseErrors).Count 'bootstrap parses before InstallRoot default audit'
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'InstallRoot' } | Select-Object -First 1
    Assert-CcodTrue ($null -ne $param) 'InstallRoot parameter exists'
    Assert-CcodTrue (-not $param.Attributes.Where({ $_.TypeName.Name -ceq 'Parameter' -and $_.NamedArguments.Where({ $_.ArgumentName -ceq 'Mandatory' -and $_.Argument.Extent.Text -match 'true' }) }).Count) 'InstallRoot is not mandatory'
    Assert-CcodTrue ($param.DefaultValue.Extent.Text -match 'PSScriptRoot') 'InstallRoot defaults to PSScriptRoot for scheduled-task launches'
    $entryMode = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'EntryMode' } | Select-Object -First 1
    Assert-CcodTrue ($null -ne $entryMode -and $entryMode.DefaultValue.Extent.Text -match "'Explicit'") 'bootstrap defaults manual launches to Explicit entry mode'
    Assert-CcodTrue (@($entryMode.Attributes | Where-Object { $_.TypeName.Name -ceq 'ValidateSet' }).Count -eq 1) 'bootstrap constrains entry mode to the declared safe modes'
}

$results | Format-Table -AutoSize
Write-Host ("Bootstrap self-test passed: {0}" -f $results.Count)
