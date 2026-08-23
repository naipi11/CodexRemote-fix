$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$workerPath = Join-Path $repositoryRoot 'src\persistence\LifecycleWorker.ps1'
if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) { throw "Lifecycle worker is missing: $workerPath" }
. $workerPath

function New-CcodLifecycleWorkerFixtureRequest {
    param([string]$Action='Inspect',[string]$RuntimeId='2.5.0-a',[UInt64]$Generation=4,[UInt64]$Epoch=9)
    [pscustomobject][ordered]@{
        schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';action=$Action
        runtimeId=$RuntimeId;runtimeGeneration=$Generation;leaseEpoch=$Epoch
        ownerIdentity=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        notBeforeUtc='2030-02-03T04:05:10.0000000Z';timeoutMilliseconds=45000
    }
}

function New-CcodLifecycleWorkerHarness {
    param([string]$Name,[string]$Action='Inspect')
    $install=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-lifecycle-worker-$Name-"+[guid]::NewGuid().ToString('N'))))
    $workers=Join-Path $install 'state\workers';[IO.Directory]::CreateDirectory($workers)|Out-Null
    $request=New-CcodLifecycleWorkerFixtureRequest -Action $Action
    $requestPath=[IO.Path]::GetFullPath((Join-Path $workers ("lifecycle-$($request.transactionId).request.json")))
    $resultPath=[IO.Path]::GetFullPath((Join-Path $workers ("lifecycle-$($request.transactionId).result.json")))
    [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $world=[pscustomobject]@{FenceCalls=0;ControllerCalls=0;LaunchCalls=0;ObserveCalls=0;Writes=0;Written=$null;Stdout=@()}
    $closure=@('src/check-package.mjs','src/runtime/orchestrator.js','src/runtime/main-payload.js','src/persistence/LifecycleWorker.ps1','src/persistence/SessionController.ps1','src/persistence/modules/CompatibilityProbe.psm1','src/persistence/modules/PersistenceIO.psm1','src/persistence/modules/StateStore.psm1','src/persistence/modules/ProcessControl.psm1','src/persistence/modules/RendererIntegration.psm1','src/persistence/modules/TransitionJournal.psm1','src/persistence/modules/SessionEngine.psm1','src/persistence/modules/RuntimeManifest.psm1','src/persistence/modules/LifecycleEpoch.psm1','src/persistence/modules/KernelObjects.psm1','src/persistence/modules/WorkerRuntime.psm1')
    $manifest=[pscustomobject][ordered]@{schemaVersion=1;projectVersion='2.5.0';runtimeId='2.5.0-a';files=@($closure|ForEach-Object{[pscustomobject][ordered]@{path=$_;length=1;sha256=('a'*64)}})}
    $context=[pscustomobject][ordered]@{InstallRoot=$install;RuntimeRoot=(Join-Path $install 'runtime\2.5.0-a');RuntimeId='2.5.0-a';RuntimeGeneration=[UInt64]4;WorkerPath=$workerPath;WorkersRoot=$workers;Manifest=$manifest}
    $controller=[pscustomobject][ordered]@{
        schemaVersion=1;action=$(if($Action -ceq 'VerifyRemote'){'Inspect'}else{$Action});ok=$true;outcome='Inspected';safeState='SpecialValidated';stage='Inspected'
        transactionId=$request.transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=$null;logFile=$null
    }
    $adapters=@{
        GetScriptPath={$workerPath}.GetNewClosure()
        GetBootstrapContext={[pscustomobject][ordered]@{InstallRoot=$install;WorkersRoot=$workers}}.GetNewClosure()
        ResolveRuntime={param($Path,$Runtime,$Generation)$context}.GetNewClosure()
        ReadRequest={param($Path)Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
        AssertFence={param($Context,$Request)$world.FenceCalls++;$true}.GetNewClosure()
        GetCurrentIdentity={ [pscustomobject][ordered]@{UserSid='S-1-5-21-1-2-3-1001';SessionId=2} }
        InvokeController={param($ActionName,$RequestValue,$ContextValue)$world.ControllerCalls++;$controller}.GetNewClosure()
        RequestOrdinaryLaunch={param($RequestValue,$ContextValue)$world.LaunchCalls++;[pscustomobject][ordered]@{outcome='LaunchRequested';requestedAtUtc=$RequestValue.notBeforeUtc;launcherPid=777}}.GetNewClosure()
        ObserveOrdinary={param($RequestValue,$ContextValue)$world.ObserveCalls++;[pscustomobject][ordered]@{Pid=888;CreationTimeUtc='2030-02-03T04:05:11.0000000Z'}}.GetNewClosure()
        WriteResult={param($Path,$Value)$world.Writes++;$world.Written=$Value}.GetNewClosure()
        WriteStdout={param($Line)$world.Stdout+=@($Line)}.GetNewClosure()
        WriteStderr={param($Line)}
    }
    [pscustomobject]@{Install=$install;Workers=$workers;Request=$request;RequestPath=$requestPath;ResultPath=$resultPath;World=$world;Context=$context;Controller=$controller;Adapters=$adapters}
}

function Get-CcodWorkerErrorCode($Run){ if($null -eq $Run.Result.error){return $null};return $Run.Result.error.code }

$results=@();$roots=[Collections.Generic.List[string]]::new()
try {
    $results += Invoke-CcodTest 'worker rejects runtime generation and exact request-shape mismatches before dispatch' {
        foreach ($case in @('Runtime','Generation','Extra','UnknownAction')) {
            $h=New-CcodLifecycleWorkerHarness -Name $case;$roots.Add($h.Install)
            if($case -ceq 'Runtime'){$h.Context.RuntimeId='2.5.0-other'}
            elseif($case -ceq 'Generation'){$h.Context.RuntimeGeneration=[UInt64]5}
            elseif($case -ceq 'Extra'){$h.Request|Add-Member -NotePropertyName extra -NotePropertyValue $true;[IO.File]::WriteAllText($h.RequestPath,($h.Request|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
            else{$h.Request.action='Recover';[IO.File]::WriteAllText($h.RequestPath,($h.Request|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
            $run=Invoke-CcodLifecycleWorker -RequestPath $h.RequestPath -ResultPath $h.ResultPath -Adapters $h.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$case exits nonzero"
            Assert-CcodEqual 0 ($h.World.ControllerCalls+$h.World.LaunchCalls+$h.World.ObserveCalls) "$case dispatches no operation"
        }
    }

    $results += Invoke-CcodTest 'worker rejects an active manifest missing one operation dependency' {
        $h=New-CcodLifecycleWorkerHarness -Name closure;$roots.Add($h.Install)
        $h.Context.Manifest.files=@($h.Context.Manifest.files|Where-Object{$_.path -cne 'src/persistence/modules/SessionEngine.psm1'})
        $run=Invoke-CcodLifecycleWorker -RequestPath $h.RequestPath -ResultPath $h.ResultPath -Adapters $h.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'incomplete runtime closure fails'
        Assert-CcodEqual 'CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED' (Get-CcodWorkerErrorCode $run) 'incomplete closure is unauthorized'
        Assert-CcodEqual 0 ($h.World.ControllerCalls+$h.World.LaunchCalls+$h.World.ObserveCalls) 'incomplete closure dispatches nothing'
    }

    $results += Invoke-CcodTest 'worker rejects alias and reparse framing paths' {
        $alias=New-CcodLifecycleWorkerHarness -Name alias;$roots.Add($alias.Install)
        $run=Invoke-CcodLifecycleWorker -RequestPath $alias.RequestPath -ResultPath $alias.RequestPath -Adapters $alias.Adapters
        Assert-CcodEqual 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' (Get-CcodWorkerErrorCode $run) 'request/result alias rejected'
        Assert-CcodEqual 0 $alias.World.ControllerCalls 'alias dispatches nothing'

        $reparse=New-CcodLifecycleWorkerHarness -Name reparse;$roots.Add($reparse.Install)
        $ordinaryGetItem={param($Path,$AllowMissing)if($Path -ceq $reparse.RequestPath){return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint;PSIsContainer=$false}};if($AllowMissing -and -not(Test-Path -LiteralPath $Path)){return $null};Get-Item -LiteralPath $Path -Force -ErrorAction Stop}.GetNewClosure()
        $reparse.Adapters.GetItem=$ordinaryGetItem
        $run=Invoke-CcodLifecycleWorker -RequestPath $reparse.RequestPath -ResultPath $reparse.ResultPath -Adapters $reparse.Adapters
        Assert-CcodEqual 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' (Get-CcodWorkerErrorCode $run) 'reparse request rejected'
        Assert-CcodEqual 0 $reparse.World.ControllerCalls 'reparse dispatches nothing'
    }

    $results += Invoke-CcodTest 'stale fence prevents operation and final result publication' {
        $h=New-CcodLifecycleWorkerHarness -Name stale;$roots.Add($h.Install)
        $h.Adapters.AssertFence={param($Context,$Request)$exception=[InvalidOperationException]::new('stale');throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$Request)}
        $run=Invoke-CcodLifecycleWorker -RequestPath $h.RequestPath -ResultPath $h.ResultPath -Adapters $h.Adapters
        Assert-CcodEqual 'CCOD_LIFECYCLE_FENCE_STALE' (Get-CcodWorkerErrorCode $run) 'stable stale-fence code returned'
        Assert-CcodEqual 0 $h.World.ControllerCalls 'stale fence prevents controller operation'
        Assert-CcodEqual 0 $h.World.Writes 'stale fence cannot publish a mutable result'
    }

    $results += Invoke-CcodTest 'uncorrelated controller result fails closed after exactly one operation' {
        $h=New-CcodLifecycleWorkerHarness -Name correlation;$roots.Add($h.Install)
        $h.Controller.transactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $run=Invoke-CcodLifecycleWorker -RequestPath $h.RequestPath -ResultPath $h.ResultPath -Adapters $h.Adapters
        Assert-CcodEqual 1 $h.World.ControllerCalls 'one controller operation ran'
        Assert-CcodEqual 1 $run.ExitCode 'uncorrelated result fails'
        Assert-CcodEqual 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' (Get-CcodWorkerErrorCode $run) 'uncorrelated result code'
        Assert-CcodEqual 1 $h.World.Writes 'one correlated public failure is published'
    }

    $results += Invoke-CcodTest 'ordinary launch operation returns receipt semantics only' {
        $h=New-CcodLifecycleWorkerHarness -Name launch -Action RequestOrdinaryLaunch;$roots.Add($h.Install)
        $run=Invoke-CcodLifecycleWorker -RequestPath $h.RequestPath -ResultPath $h.ResultPath -Adapters $h.Adapters
        Assert-CcodEqual 0 $run.ExitCode 'launch receipt succeeds'
        Assert-CcodEqual 1 $h.World.LaunchCalls 'one launch requested'
        Assert-CcodEqual 0 $h.World.ObserveCalls 'launch operation does not observe a process'
        Assert-CcodEqual 'schemaVersion,transactionId,action,ok,outcome,observation,error' (($run.Result.PSObject.Properties.Name)-join ',') 'public result exact shape'
        Assert-CcodEqual LaunchRequested $run.Result.outcome 'outcome is receipt only'
        Assert-CcodEqual NoCodex $run.Result.observation 'receipt does not claim a process snapshot'
        Assert-CcodEqual $null $run.Result.PSObject.Properties['snapshot'] 'no snapshot property exists'
    }

    $results += Invoke-CcodTest 'each worker action dispatches exactly one operation and one correlated result' {
        foreach($action in @('Inspect','Close','RequestOrdinaryLaunch','ObserveOrdinary','Apply','VerifyRemote')){
            $h=New-CcodLifecycleWorkerHarness -Name $action -Action $action;$roots.Add($h.Install)
            if($action -ceq 'Close'){$h.Controller.action='Close';$h.Controller.outcome='Closed';$h.Controller.safeState='Closed'}
            elseif($action -ceq 'Apply'){$h.Controller.action='Apply';$h.Controller.outcome='Activated';$h.Controller.safeState='SpecialValidated'}
            $run=Invoke-CcodLifecycleWorker -RequestPath $h.RequestPath -ResultPath $h.ResultPath -Adapters $h.Adapters
            Assert-CcodEqual 0 $run.ExitCode "$action succeeds"
            Assert-CcodEqual 1 ($h.World.ControllerCalls+$h.World.LaunchCalls+$h.World.ObserveCalls) "$action executes one operation"
            Assert-CcodEqual 1 $h.World.Writes "$action publishes once"
            Assert-CcodEqual $h.Request.transactionId $run.Result.transactionId "$action result correlated"
            Assert-CcodEqual $action $run.Result.action "$action result action correlated"
        }
    }
} finally {
    foreach($path in $roots){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
}

$results|Format-Table -AutoSize
Write-Host ("Lifecycle worker self-tests passed: {0}" -f $results.Count)
