$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleEpoch.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\WorkerRuntime.psm1') -Force
. (Join-Path $repositoryRoot 'src\persistence\SessionController.ps1')

function New-CcodControllerRequest([string]$Action='Inspect',[string]$TransactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda'){
    if($Action -cne 'Recover'){return New-CcodControllerV2Request -Action $Action -TransactionId $TransactionId}
    [pscustomobject][ordered]@{schemaVersion=1;action=$Action;transactionId=$TransactionId;runtimeId='runtime-1';supervisorIdentity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'};source=$null;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=30000;restartOrdinary=$true}
}
function New-CcodControllerV2Request([string]$Action='Inspect',[string]$TransactionId='11111111-2222-3333-4444-555555555555'){
    [pscustomobject][ordered]@{
        schemaVersion=2;action=$Action;transactionId=$TransactionId;runtimeId='runtime-1';runtimeGeneration=[UInt64]4;leaseEpoch=[UInt64]9
        ownerIdentity=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        supervisorIdentity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        source=$null;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=30000;restartOrdinary=($Action -cne 'Close')
    }
}
function New-CcodControllerPaths([string]$Root){
    $stable=Join-Path $Root 'install';$state=Join-Path $stable 'state';$runtime=Join-Path $stable 'runtime\runtime-1'
    [pscustomobject][ordered]@{StateRoot=[IO.Path]::GetFullPath($state);TransitionPath=[IO.Path]::GetFullPath((Join-Path $state 'transition.json'));TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\transactions.log'));SessionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\session.log'));CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\check-package.mjs'));OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\orchestrator.js'));MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\main-payload.js'))}
}
function New-CcodControllerResult([string]$Action,[string]$TransactionId,[string]$Outcome='Inspected'){
    $safe=if($Outcome -ceq 'Closed'){'Closed'}elseif($Outcome -ceq 'Recovered'){'OrdinaryRunning'}else{'NoCodex'}
    [pscustomobject][ordered]@{schemaVersion=1;action=$Action;ok=$true;outcome=$Outcome;safeState=$safe;stage='Completed';transactionId=$TransactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=$null;logFile=$null}
}

$script:CcodControllerTestUserSid='S-1-5-21-111-222-333-1001'
$script:CcodControllerTestSessionId=[int]1

function New-CcodControllerTestLease([string]$Kind,[string]$Outcome='Acquired',[bool]$Abandoned=$false){
    $name=if($Kind -ceq 'AccountTransition'){Get-CcodKernelObjectName -Kind $Kind -UserSid $script:CcodControllerTestUserSid}else{Get-CcodKernelObjectName -Kind $Kind -UserSid $script:CcodControllerTestUserSid -SessionId $script:CcodControllerTestSessionId}
    if($Outcome -ceq 'TimedOut'){
        return [pscustomobject][ordered]@{SchemaVersion=1;Name=$name;Kind=$Kind;Outcome='TimedOut';CreatedNew=$true;Abandoned=$false;Handle=$null;OwnerManagedThreadId=$null;Released=$true}
    }
    [pscustomobject][ordered]@{SchemaVersion=1;Name=$name;Kind=$Kind;Outcome='Acquired';CreatedNew=$true;Abandoned=$Abandoned;Handle=[Threading.Mutex]::new($false);OwnerManagedThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId;Released=$false}
}

function Close-CcodControllerTestLease($Lease){
    if($null -eq $Lease -or $Lease -isnot [pscustomobject]){return $false}
    if($null -ne $Lease.PSObject.Properties['Handle'] -and $Lease.Handle -is [Threading.Mutex]){$Lease.Handle.Dispose();$Lease.Handle=$null}
    if($null -ne $Lease.PSObject.Properties['Released'] -and $Lease.PSObject.Properties['Released'].MemberType -eq [Management.Automation.PSMemberTypes]::NoteProperty){$Lease.Released=$true}
    return $true
}

function New-CcodMalformedControllerTestLease([string]$Case,[string]$Kind='AccountTransition'){
    if($Case -ceq 'Minimal'){return [pscustomobject][ordered]@{Kind=$Kind}}
    if($Case -ceq 'Dictionary'){
        $name=if($Kind-ceq'AccountTransition'){Get-CcodKernelObjectName -Kind $Kind -UserSid $script:CcodControllerTestUserSid}else{Get-CcodKernelObjectName -Kind $Kind -UserSid $script:CcodControllerTestUserSid -SessionId $script:CcodControllerTestSessionId}
        return [ordered]@{SchemaVersion=1;Name=$name;Kind=$Kind;Outcome='TimedOut';CreatedNew=$false;Abandoned=$false;Handle=$null;OwnerManagedThreadId=$null;Released=$true}
    }
    $timeout=$Case.StartsWith('Timeout',[StringComparison]::Ordinal)
    $lease=New-CcodControllerTestLease -Kind $Kind -Outcome $(if($timeout){'TimedOut'}else{'Acquired'})
    switch($Case){
        'MissingField' {[void]$lease.PSObject.Properties.Remove('Name')}
        'ExtraField' {$lease|Add-Member -NotePropertyName Extra -NotePropertyValue $true}
        'WrongOrder' {$lease=[pscustomobject][ordered]@{Name=$lease.Name;SchemaVersion=$lease.SchemaVersion;Kind=$lease.Kind;Outcome=$lease.Outcome;CreatedNew=$lease.CreatedNew;Abandoned=$lease.Abandoned;Handle=$lease.Handle;OwnerManagedThreadId=$lease.OwnerManagedThreadId;Released=$lease.Released}}
        'ScriptProperty' {[void]$lease.PSObject.Properties.Remove('Released');$lease|Add-Member -MemberType ScriptProperty -Name Released -Value {$false}}
        'SchemaType' {$lease.SchemaVersion=[long]1}
        'SchemaValue' {$lease.SchemaVersion=2}
        'NameMismatch' {$lease.Name=$lease.Name+'.foreign'}
        'NameType' {$lease.Name=7}
        'KindCase' {$lease.Kind='accounttransition'}
        'KindMismatch' {$lease.Kind=$(if($Kind-ceq'Transition'){'AccountTransition'}else{'Transition'})}
        'KindType' {$lease.Kind=7}
        'OutcomeCase' {$lease.Outcome='acquired'}
        'OutcomeUnknown' {$lease.Outcome='Unknown'}
        'OutcomeType' {$lease.Outcome=7}
        'CreatedNewType' {$lease.CreatedNew=1}
        'AbandonedType' {$lease.Abandoned=0}
        'AcquiredHandleNull' {$lease.Handle.Dispose();$lease.Handle=$null}
        'AcquiredHandleType' {$lease.Handle.Dispose();$lease.Handle='not-a-mutex'}
        'AcquiredHandleClosed' {$lease.Handle.Dispose()}
        'AcquiredOwnerType' {$lease.OwnerManagedThreadId=[long]$lease.OwnerManagedThreadId}
        'AcquiredOwnerMismatch' {$lease.OwnerManagedThreadId=[int]($lease.OwnerManagedThreadId+1)}
        'AcquiredOwnerZero' {$lease.OwnerManagedThreadId=[int]0}
        'AcquiredReleased' {$lease.Released=$true}
        'ReleasedType' {$lease.Released=0}
        'TimeoutAbandoned' {$lease.Abandoned=$true}
        'TimeoutHandle' {$lease.Handle=[Threading.Mutex]::new($false)}
        'TimeoutOwner' {$lease.OwnerManagedThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId}
        'TimeoutNotReleased' {$lease.Released=$false}
        default {throw "unknown malformed lease case $Case"}
    }
    return $lease
}

function Merge-CcodControllerTestAdapters([hashtable]$Overrides){
    $resolved=@{
        GetIdentity={ [pscustomobject][ordered]@{UserSid=$script:CcodControllerTestUserSid;SessionId=$script:CcodControllerTestSessionId} }
        GetSupervisorProcess={param($ProcessId)[pscustomobject][ordered]@{Pid=[int]$ProcessId;CreationTimeUtc='2030-02-03T03:00:00.0000000Z';SessionId=[int]1}}
        StartStopwatch={ [pscustomobject]@{Marker='test-clock'} }
        GetElapsedMilliseconds={param($Clock)[long]0}
        EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)New-CcodControllerTestLease -Kind $Kind}
        ExitMutex={param($Lease)Close-CcodControllerTestLease $Lease}
        ReadJournal={param($Path)$null}
        UtcNow={ [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime() }
        AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)$true}
        GetDelegatedOwnership={
            $owner=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
            [pscustomobject][ordered]@{schemaVersion=1;lease=(New-CcodControllerTestLease AccountTransition);epoch=[UInt64]9;runtimeId='runtime-1';runtimeGeneration=[UInt64]4;ownerIdentity=$owner;released=$false}
        }
    }
    if($null -ne $Overrides){foreach($name in $Overrides.Keys){$resolved[$name]=$Overrides[$name]}}
    return $resolved
}

function Invoke-CcodLeasedTestController {
    param($Request,$Paths,[string]$ResultPath,[hashtable]$Adapters)
    Invoke-CcodSessionController -Request $Request -Paths $Paths -ResultPath $ResultPath -Adapters (Merge-CcodControllerTestAdapters $Adapters)
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-controller-selftest-'+[guid]::NewGuid().ToString('N'))
try{
    $paths=New-CcodControllerPaths $root;$resultPath=Join-Path $root 'result.json'
    Invoke-CcodTest 'controller exposes ProcessControl globally so legacy provenance parses the exact child command line' {
        $processControl=Get-Module -Name ProcessControl -ErrorAction SilentlyContinue
        Assert-CcodTrue ($null -ne $processControl) 'SessionController imports ProcessControl into the controller-visible module table'
        $adapter=Get-CcodControllerAdapters $null
        $commandLine='powershell.exe -NoProfile -File "C:\work\child.ps1" -RequestPath "C:\Temp\request.json"'
        $tokens=@(& $adapter.ParseProcessCommandLine $commandLine)
        Assert-CcodEqual 'powershell.exe,-NoProfile,-File,C:\work\child.ps1,-RequestPath,C:\Temp\request.json' ($tokens -join ',') 'legacy provenance receives the native parsed process command-line tokens instead of an empty array'
    }
    Invoke-CcodTest 'schema-v2 controller dispatches only the fenced Inspect Close Apply and RepairRenderer allow-list' {
        foreach($action in @('Inspect','Close','Apply','RepairRenderer')){
            $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerV2Request -Action $action
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EngineInvoker={param($Action,$Request,$Paths,$EngineAdapters)$events.Add("engine:$Action");& $EngineAdapters.AssertLifecycleFence $Request.runtimeGeneration $Request.leaseEpoch $Request.ownerIdentity|Out-Null;New-CcodControllerResult $Action $Request.transactionId $(if($Action -ceq 'Close'){'Closed'}else{'Inspected'})}.GetNewClosure()
                AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)$events.Add("fence:${RuntimeGeneration}:${LeaseEpoch}:$($OwnerIdentity.pid)");$true}.GetNewClosure()
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodTrue (@($events|Where-Object{$_ -ceq "engine:$action"}).Count -eq 1) "$action dispatches exactly once"
            Assert-CcodTrue (@($events|Where-Object{$_ -ceq 'fence:4:9:401'}).Count -ge 3) "$action engine and both result commits revalidate the exact fence"
            Assert-CcodEqual 0 $run.ExitCode "$action returns a safe framed result"
        }
        foreach($action in @('RepairStale','Recover')){
            $invalid=New-CcodControllerV2Request -Action Inspect;$invalid.action=$action
            $run=Invoke-CcodLeasedTestController -Request $invalid -Paths $paths -ResultPath $resultPath -Adapters @{EngineInvoker={throw 'must not dispatch'};WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}}
            Assert-CcodEqual 'CCOD_REQUEST_INVALID' $run.Result.error.code "schema-v2 $action is outside the action allow-list"
        }
    }

    Invoke-CcodTest 'schema-v2 proves delegated ownership by reentering account then acquiring session transition' {
        foreach($action in @('Inspect','Close','Apply')){
            $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerV2Request -Action $action
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)$events.Add('fence');$true}.GetNewClosure()
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind}.GetNewClosure()
                ReadJournal={param($Path)$events.Add('journal');$null}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths,$EngineAdapters)$events.Add("engine:$Action");New-CcodControllerResult $Action $Request.transactionId $(if($Action-ceq'Close'){'Closed'}elseif($Action-ceq'Apply'){'NoAction'}else{'Inspected'})}.GetNewClosure()
                ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");Close-CcodControllerTestLease $Lease}.GetNewClosure()
                WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure();WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure();WriteStderr={param($Line)}
            }
            Assert-CcodEqual (('fence,enter:AccountTransition,enter:Transition,journal,engine:{0},fence,write,exit:Transition,exit:AccountTransition,fence,write,stdout' -f $action)) ($events-join ',') "$action validates delegation then proves real reentrant account ownership before session work"
            Assert-CcodEqual 1 @($events|Where-Object{$_-ceq'enter:AccountTransition'}).Count "$action reenters the worker-held account lease exactly once"
            Assert-CcodEqual 0 $run.ExitCode "$action delegated operation succeeds"
        }
    }

    Invoke-CcodTest 'stale delegated lifecycle ownership is rejected before the session lease' {
        $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerV2Request -Action Close
        $adapters=Merge-CcodControllerTestAdapters @{
            GetDelegatedOwnership={
                $owner=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
                [pscustomobject][ordered]@{schemaVersion=1;lease=(New-CcodControllerTestLease AccountTransition);epoch=[UInt64]9;runtimeId='runtime-1';runtimeGeneration=[UInt64]4;ownerIdentity=$owner;released=$false}
            }
            AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)$events.Add('fence');$exception=[InvalidOperationException]::new('stale');throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$OwnerIdentity)}.GetNewClosure()
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");throw 'must not enter'}.GetNewClosure()
            WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodThrows {Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters $adapters|Out-Null} 'CCOD_LIFECYCLE_FENCE_STALE'
        Assert-CcodEqual 'fence' ($events-join ',') 'stale owner reaches no transition mutex or engine operation'
    }

    Invoke-CcodTest 'unrelated live process with valid epoch facts cannot operate without worker-held delegation' {
        $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerV2Request -Action Apply
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            GetDelegatedOwnership={$null};EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add($Kind);throw 'must not acquire'};EngineInvoker={throw 'must not operate'}
            WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $run.Result.error.code 'direct schema-v2 call has no delegated mutation authority'
        Assert-CcodEqual 0 $events.Count 'unrelated process reaches no mutex or engine operation'
    }

    Invoke-CcodTest 'a stale schema-v2 fence propagates before process mutation and before final result publication' {
        $request=New-CcodControllerV2Request -Action Close;$world=[pscustomobject]@{StopCalls=0;Writes=0}
        $staleBeforeStop=Merge-CcodControllerTestAdapters @{
            AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)
                $exception=[InvalidOperationException]::new('stale lifecycle owner')
                throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$OwnerIdentity)
            }
            EngineInvoker={param($Action,$Request,$Paths,$EngineAdapters)& $EngineAdapters.AssertLifecycleFence $Request.runtimeGeneration $Request.leaseEpoch $Request.ownerIdentity|Out-Null;$world.StopCalls++;New-CcodControllerResult $Action $Request.transactionId Closed}.GetNewClosure()
            WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodThrows { Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters $staleBeforeStop } 'CCOD_LIFECYCLE_FENCE_STALE'
        Assert-CcodEqual 0 $world.StopCalls 'stale owner never stops Codex'

        $finalWorld=[pscustomobject]@{Writes=0}
        $staleFinal=Merge-CcodControllerTestAdapters @{
            EngineInvoker={param($Action,$Request,$Paths,$EngineAdapters)New-CcodControllerResult $Action $Request.transactionId Closed}.GetNewClosure()
            AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)
                if($finalWorld.Writes -ge 1){$exception=[InvalidOperationException]::new('stale before final result');throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$OwnerIdentity)}
                $true
            }.GetNewClosure()
            WriteResult={param($Path,$Value)$finalWorld.Writes++}.GetNewClosure();WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodThrows { Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters $staleFinal } 'CCOD_LIFECYCLE_FENCE_STALE'
        Assert-CcodEqual 1 $finalWorld.Writes 'stale owner cannot publish the final controller result'
    }

    Invoke-CcodTest 'schema-v1 Recover has no public bypass and requires exact wrapper parent provenance' {
        $request=New-CcodControllerRequest -Action Recover;$calls=[pscustomobject]@{Engine=0}
        $blocked=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters (Merge-CcodControllerTestAdapters @{LegacyRecoverAuthorized=$true;Capability=[object]::new();EngineInvoker={param($Action,$Request,$Paths)$calls.Engine++;throw 'must not dispatch'}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}})
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $blocked.Result.error.code 'ordinary callers cannot enter legacy Recover'
        Assert-CcodEqual 0 $calls.Engine 'blocked legacy request has no engine side effect'
        Assert-CcodTrue (-not (Get-Command Invoke-CcodSessionController).Parameters.ContainsKey('AllowLegacyRecover')) 'public controller surface has no self-authorization switch'
        Assert-CcodEqual $null (Get-Command Invoke-CcodSessionControllerCore -ErrorAction SilentlyContinue) 'dot-sourcing exposes no authorization-bearing controller core'
        Assert-CcodEqual $null (Get-Command Invoke-CcodVerifiedLegacyRecoverController -ErrorAction SilentlyContinue) 'dot-sourcing exposes no callable verified-legacy dispatcher'
        Assert-CcodEqual $null (Get-Variable CcodControllerExecutionLegacyInvoker -ValueOnly -ErrorAction SilentlyContinue) 'dot-sourcing retains no execution-only legacy capability closure'
        foreach($command in @(Get-Command -CommandType Function|Where-Object{$_.ScriptBlock.File -ceq (Join-Path $repositoryRoot 'src\persistence\SessionController.ps1')})){
            Assert-CcodTrue (-not $command.Parameters.ContainsKey('LegacyRecoverAuthorized')) "$($command.Name) cannot accept legacy authorization"
        }
        $publicText=(Get-Command Invoke-CcodSessionController -CommandType Function).ScriptBlock.ToString()
        Assert-CcodTrue ($publicText -cnotmatch 'LegacyRecoverAuthorized|legacy capability') 'public controller text contains no legacy authorization branch or token'
        $reconstructed=[scriptblock]::Create($publicText.Replace('$LegacyRecoverAuthorized=$false','$LegacyRecoverAuthorized=$true'))
        $beforeReconstruction=$calls.Engine
        $reconstructedRun=& $reconstructed $request $paths $resultPath (Merge-CcodControllerTestAdapters @{EngineInvoker={param($Action,$Request,$Paths)$calls.Engine++;New-CcodControllerResult $Action $Request.transactionId Recovered}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}})
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $reconstructedRun.Result.error.code 'prior public-text replacement cannot reconstruct legacy authority'
        Assert-CcodEqual $beforeReconstruction $calls.Engine 'reconstructed public scriptblock cannot reach legacy engine'

        $legacyRoot=[IO.Path]::GetFullPath((Join-Path $root 'legacy-temp\CodexControlOtherDevices'));$nonce='0123456789abcdef0123456789abcdef'
        $requestPath=[IO.Path]::GetFullPath((Join-Path $legacyRoot "start-$nonce-request.json"));$legacyResultPath=[IO.Path]::GetFullPath((Join-Path $legacyRoot "start-$nonce-result.json"))
        $runtimeRoot=[IO.Path]::GetFullPath((Join-Path $root 'install\runtime\runtime-1'));$controller=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\SessionController.ps1'))
        $wrapper=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'Start-CodexControlOtherDevices.ps1'));$powershell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $runtimeContext=[pscustomobject][ordered]@{InstallRoot=[IO.Path]::GetFullPath((Join-Path $root 'install'));RuntimeRoot=$runtimeRoot;RuntimeId='runtime-1';ControllerPath=$controller;Manifest=[pscustomobject][ordered]@{files=@([pscustomobject][ordered]@{path='Start-CodexControlOtherDevices.ps1'})}}
        $current=[pscustomobject][ordered]@{Pid=700;CreationTimeUtc='2030-02-03T03:00:01.0000000Z';SessionId=1;UserSid=$script:CcodControllerTestUserSid;Path=$powershell;CommandLine='child';ParentPid=11}
        $parent=[pscustomobject][ordered]@{Pid=11;CreationTimeUtc='2030-02-03T03:00:00.0000000Z';SessionId=1;UserSid=$script:CcodControllerTestUserSid;Path=$powershell;CommandLine='parent';ParentPid=10}
        $leafChecks=[pscustomobject]@{Count=0}
        $validAdapters=Merge-CcodControllerTestAdapters @{
            GetLegacyTempRoot={$legacyRoot}.GetNewClosure();TestLegacyPathSafe={param($Path)$true};GetCurrentProcessId={700}
            TestLegacyFileSafe={param($Path)$leafChecks.Count++;$true}.GetNewClosure()
            GetProcessProvenance={param($ProcessId)if([int]$ProcessId -eq 700){$current}elseif([int]$ProcessId -eq 11){$parent}else{$null}}.GetNewClosure()
            ParseProcessCommandLine={param($CommandLine)if($CommandLine -ceq 'child'){@($powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-RequestPath',$requestPath,'-ResultPath',$legacyResultPath)}else{@($powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,'-RestartCodex')}}.GetNewClosure()
            GetApprovedPowerShellPath={$powershell}.GetNewClosure()
            ReadJournal={param($Path)[pscustomobject]@{transactionId='1b2c5c27-e6e3-4ae4-a876-a59418519d41';stage='OrdinaryStopped'}}
            EngineInvoker={param($Action,$Request,$Paths)$calls.Engine++;New-CcodControllerResult $Action $Request.transactionId Recovered}.GetNewClosure()
            WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        $allowed=Test-CcodLegacyRecoverProvenance -Request $request -RequestPath $requestPath -ResultPath $legacyResultPath -RuntimeContext $runtimeContext -Adapter $validAdapters
        Assert-CcodEqual $true $allowed 'manifest-bound wrapper parent provenance admits exact legacy Recover'
        Assert-CcodEqual 2 $leafChecks.Count 'both request and result leaves are proven regular non-reparse files'
        Assert-CcodEqual 0 $calls.Engine 'provenance checker cannot dispatch the legacy engine'

        $missingRestart=$validAdapters.Clone();$missingRestart.ParseProcessCommandLine={param($CommandLine)if($CommandLine -ceq 'child'){@($powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-RequestPath',$requestPath,'-ResultPath',$legacyResultPath)}else{@($powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper)}}.GetNewClosure()
        Assert-CcodEqual $false (Test-CcodLegacyRecoverProvenance -Request $request -RequestPath $requestPath -ResultPath $legacyResultPath -RuntimeContext $runtimeContext -Adapter $missingRestart) 'Start Recover requires the parent RestartCodex semantic'
        $unsafeLeaf=$validAdapters.Clone();$unsafeLeaf.TestLegacyFileSafe={param($Path)$false}
        Assert-CcodEqual $false (Test-CcodLegacyRecoverProvenance -Request $request -RequestPath $requestPath -ResultPath $legacyResultPath -RuntimeContext $runtimeContext -Adapter $unsafeLeaf) 'a reparse or non-file request/result leaf rejects legacy recovery'

        $testVariant={
            param([string]$Prefix,[string]$WrapperLeaf,[string[]]$Tail,[bool]$RestartOrdinary,[int]$TimeoutMilliseconds)
            $variantRequest=New-CcodControllerRequest -Action Recover;$variantRequest.restartOrdinary=$RestartOrdinary;$variantRequest.timeoutMilliseconds=$TimeoutMilliseconds
            $variantRequestPath=[IO.Path]::GetFullPath((Join-Path $legacyRoot "$Prefix-$nonce-request.json"));$variantResultPath=[IO.Path]::GetFullPath((Join-Path $legacyRoot "$Prefix-$nonce-result.json"))
            $installerRoot=$null;$manifestPath=$WrapperLeaf;$manifestRecord=[pscustomobject][ordered]@{path=$manifestPath}
            if($Prefix -ceq 'uninstall'){
                $installerRoot=[IO.Path]::GetFullPath((Join-Path $root 'installer'))
                $variantWrapper=[IO.Path]::GetFullPath((Join-Path $installerRoot 'src\persistence\UninstallBootstrap.ps1'))
                $manifestPath='src/persistence/UninstallBootstrap.ps1';$manifestRecord=[pscustomobject][ordered]@{path=$manifestPath;sha256=('a'*64)}
            }else{$variantWrapper=[IO.Path]::GetFullPath((Join-Path $runtimeRoot $WrapperLeaf))}
            $variantRuntime=[pscustomobject][ordered]@{InstallRoot=$runtimeContext.InstallRoot;RuntimeRoot=$runtimeRoot;RuntimeId='runtime-1';ControllerPath=$controller;Manifest=[pscustomobject][ordered]@{files=@($manifestRecord)}}
            $variantAdapters=$validAdapters.Clone();$tailValue=@($Tail);$powerShellValue=$powershell;$controllerValue=$controller
            $variantAdapters.ParseProcessCommandLine={param($CommandLine)if($CommandLine -ceq 'child'){@($powerShellValue,'-NoProfile','-ExecutionPolicy','Bypass','-File',$controllerValue,'-RequestPath',$variantRequestPath,'-ResultPath',$variantResultPath)}else{@($powerShellValue,'-NoProfile','-ExecutionPolicy','Bypass','-File',$variantWrapper)+$tailValue}}.GetNewClosure()
            if($Prefix -ceq 'uninstall'){$variantAdapters.GetFileSha256={param($Path)('a'*64)}.GetNewClosure()}
            Test-CcodLegacyRecoverProvenance -Request $variantRequest -RequestPath $variantRequestPath -ResultPath $variantResultPath -RuntimeContext $variantRuntime -Adapter $variantAdapters
        }.GetNewClosure()
        Assert-CcodEqual $true (& $testVariant 'reset' 'Reset-CodexControlOtherDevices.ps1' @() $true 30000) 'default Reset maps exactly to restartOrdinary true'
        Assert-CcodEqual $true (& $testVariant 'reset' 'Reset-CodexControlOtherDevices.ps1' @('-DoNotRestart') $false 30000) 'Reset DoNotRestart maps exactly to restartOrdinary false'
        Assert-CcodEqual $false (& $testVariant 'reset' 'Reset-CodexControlOtherDevices.ps1' @('-DoNotRestart') $true 30000) 'Reset semantic mismatch is rejected'
        Assert-CcodEqual $false (& $testVariant 'reset' 'Reset-CodexControlOtherDevices.ps1' @() $false 30000) 'default Reset cannot claim DoNotRestart semantics'
        Assert-CcodEqual $true (& $testVariant 'start' 'Start-CodexControlOtherDevices.ps1' @('-RestartCodex','-TimeoutSeconds','60') $true 60000) 'Start timeout and restart semantics correlate exactly'
        Assert-CcodEqual $false (& $testVariant 'start' 'Start-CodexControlOtherDevices.ps1' @('-RestartCodex','-TimeoutSeconds','60') $true 30000) 'Start timeout mismatch is rejected'
        $installerRoot=[IO.Path]::GetFullPath((Join-Path $root 'installer'))
        Assert-CcodEqual $true (& $testVariant 'uninstall' 'src/persistence/UninstallBootstrap.ps1' @('-InstallerRoot',$installerRoot,'-InstallRoot',$runtimeContext.InstallRoot,'-Mode','Prepare') $true 30000) 'manifest-bound uninstall bootstrap normalization semantics correlate exactly'
        Assert-CcodEqual $false (& $testVariant 'uninstall' 'src/persistence/UninstallBootstrap.ps1' @('-KeepCurrentSpecialSession') $true 30000) 'removed uninstall options cannot dispatch Recover'

        $selfRequest=New-CcodControllerRequest -Action Recover;$selfRequest.supervisorIdentity.pid=700;$selfRequest.supervisorIdentity.creationTimeUtc=$current.CreationTimeUtc
        $forgeries=@(
            @{Name='filename-only';Request=$request;ResultPath=$legacyResultPath;Mutate={param($a)$a.GetProcessProvenance={param($ProcessId)$null}}},
            @{Name='nonce mismatch';Request=$request;ResultPath=([IO.Path]::GetFullPath((Join-Path $legacyRoot 'start-ffffffffffffffffffffffffffffffff-result.json')));Mutate={param($a)}},
            @{Name='self identity';Request=$selfRequest;ResultPath=$legacyResultPath;Mutate={param($a)}},
            @{Name='parent command line';Request=$request;ResultPath=$legacyResultPath;Mutate={param($a)$a.ParseProcessCommandLine={param($CommandLine)if($CommandLine -ceq 'child'){@($powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-RequestPath',$requestPath,'-ResultPath',$legacyResultPath)}else{@($powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File','C:\Forged\Start-CodexControlOtherDevices.ps1')}}.GetNewClosure()}}
        )
        foreach($case in $forgeries){
            $adapters=$validAdapters.Clone();& $case.Mutate $adapters
            $before=$calls.Engine
            $rejected=Test-CcodLegacyRecoverProvenance -Request $case.Request -RequestPath $requestPath -ResultPath $case.ResultPath -RuntimeContext $runtimeContext -Adapter $adapters
            Assert-CcodEqual $false $rejected "$($case.Name) forgery is rejected"
            Assert-CcodEqual $before $calls.Engine "$($case.Name) forgery never dispatches the engine"
        }
    }

    Invoke-CcodTest 'legacy provenance rejects real reparse and non-file request or result leaves where supported' {
        $leafRoot=[IO.Path]::GetFullPath((Join-Path $root 'legacy-leaves'));[IO.Directory]::CreateDirectory($leafRoot)|Out-Null
        $regular=[IO.Path]::GetFullPath((Join-Path $leafRoot 'regular.json'));[IO.File]::WriteAllText($regular,'{}',[Text.UTF8Encoding]::new($false))
        $adapter=Get-CcodControllerAdapters $null
        Assert-CcodEqual $true (& $adapter.TestLegacyFileSafe $regular) 'regular file is accepted as a legacy framing leaf'
        Assert-CcodEqual $false (& $adapter.TestLegacyFileSafe $leafRoot) 'directory leaf is rejected'
        $link=[IO.Path]::GetFullPath((Join-Path $leafRoot 'linked.json'));$linkCreated=$false
        try{New-Item -ItemType SymbolicLink -Path $link -Target $regular -ErrorAction Stop|Out-Null;$linkCreated=$true}catch{}
        if($linkCreated){Assert-CcodEqual $false (& $adapter.TestLegacyFileSafe $link) 'real symbolic-link leaf is rejected'}
    }

    Invoke-CcodTest 'writes provisional and final atomic results before exactly one compressed stdout line' {
        $events=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$captured=[pscustomobject]@{Written=$null}
        $request=New-CcodControllerRequest
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)'incidental';New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write');$captured.Written=$Value}.GetNewClosure()
            WriteStdout={param($Line)$events.Add('stdout');$stdout.Add($Line)}.GetNewClosure()
            WriteStderr={param($Line)$events.Add('stderr')}.GetNewClosure()
        }
        Assert-CcodEqual 'write,write,stdout' ($events -join ',') 'provisional and final atomic result writes precede stdout with no diagnostic leaks'
        Assert-CcodEqual 1 $stdout.Count 'stdout receives exactly one call'
        Assert-CcodTrue ($stdout[0] -cnotmatch '[\r\n]') 'compressed JSON argument contains no embedded newline'
        Assert-CcodEqual ($captured.Written|ConvertTo-Json -Depth 16 -Compress) $stdout[0] 'stdout is the same object that was written atomically'
        Assert-CcodEqual 0 $run.ExitCode 'Inspected is exit zero'
    }

    Invoke-CcodTest 'reenters the worker-held account lease then releases both leases after atomic persistence' {
        $events=[Collections.Generic.List[string]]::new();$timeouts=[Collections.Generic.List[int]]::new();$elapsed=[Collections.Generic.Queue[long]]::new();$elapsed.Enqueue(0);$elapsed.Enqueue(1250)
        $request=New-CcodControllerRequest;$run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            GetElapsedMilliseconds={param($Clock)$elapsed.Dequeue()}.GetNewClosure()
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:${Kind}:$SessionId");$timeouts.Add($TimeoutMilliseconds);New-CcodControllerTestLease $Kind}.GetNewClosure()
            ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");Close-CcodControllerTestLease $Lease}.GetNewClosure()
            ReadJournal={param($Path)$events.Add('journal');$null}.GetNewClosure()
            EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure()
            WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure()
            WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'enter:AccountTransition:,enter:Transition:1,journal,engine,write,exit:Transition,exit:AccountTransition,write,stdout' ($events -join ',') 'delegated wrapper proves the handoff account lease, releases both leases, then publishes final result'
        Assert-CcodEqual '5000,3750' ($timeouts -join ',') 'one five-second budget supplies exact remaining milliseconds to the session wait'
        Assert-CcodEqual 0 $run.ExitCode 'normal leased inspect remains safe'
    }

    Invoke-CcodTest 'publishes one exact unsafe provisional before releases and success only afterward' {
        $events=[Collections.Generic.List[string]]::new();$writes=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId Inspected}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write');$writes.Add(($Value|ConvertTo-Json -Depth 16 -Compress))}.GetNewClosure()
            ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");Close-CcodControllerTestLease $Lease}.GetNewClosure()
            WriteStdout={param($Line)$events.Add('stdout');$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'write,exit:Transition,exit:AccountTransition,write,stdout' ($events -join ',') 'no final success is durable until both delegated releases validate'
        Assert-CcodEqual 2 $writes.Count 'leased completion uses one provisional and one final atomic write'
        $provisional=$writes[0]|ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,action,ok,outcome,safeState,stage,transactionId,package,source,special,probes,recovery,error,logFile' (($provisional.PSObject.Properties.Name)-join ',') 'provisional has the exact 14-field result contract'
        Assert-CcodEqual $false $provisional.ok 'provisional is never success'
        Assert-CcodEqual 'Error' $provisional.outcome 'provisional cannot imply completion'
        Assert-CcodEqual 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' $provisional.error.code 'provisional uses the stable unpublished-result code'
        Assert-CcodEqual 'ResultWrite' $provisional.stage 'provisional has the exact unsafe stage'
        Assert-CcodEqual $request.transactionId $provisional.transactionId 'provisional preserves exact correlation'
        Assert-CcodEqual $writes[1] $stdout[0] 'final post-release success is the one stdout frame'
        Assert-CcodEqual $true (($writes[1]|ConvertFrom-Json).ok) 'success becomes durable only after releases'
        Assert-CcodEqual 0 $run.ExitCode 'validated two-phase publication remains successful'
    }

    Invoke-CcodTest 'account timeout prevents journal and engine and returns correlated busy' {
        $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action Apply
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind TimedOut}.GetNewClosure()
            ReadJournal={param($Path)$events.Add('journal');throw 'must not read journal'}.GetNewClosure()
            EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');throw 'must not invoke engine'}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure();WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'enter:AccountTransition,write,stdout' ($events -join ',') 'account timeout has no state action'
        Assert-CcodEqual 'CCOD_TRANSITION_BUSY' $run.Result.error.code 'account timeout is stable busy'
        Assert-CcodEqual 'LeaseAcquire' $run.Result.stage 'busy stage is exact'
        Assert-CcodEqual $request.transactionId $run.Result.transactionId 'busy preserves canonical correlation'
    }

    Invoke-CcodTest 'delegated session timeout releases the reentered account lease' {
        $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");if($Kind-ceq'AccountTransition'){New-CcodControllerTestLease $Kind}else{New-CcodControllerTestLease $Kind TimedOut}}.GetNewClosure()
            ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");Close-CcodControllerTestLease $Lease}.GetNewClosure()
            ReadJournal={param($Path)$events.Add('journal');throw 'must not read'}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');throw 'must not invoke'}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure();WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'enter:AccountTransition,enter:Transition,write,exit:AccountTransition,write,stdout' ($events -join ',') 'delegated session timeout closes the reentered account lease'
        Assert-CcodEqual 'CCOD_TRANSITION_BUSY' $run.Result.error.code 'delegated session timeout is stable busy'
    }

    Invoke-CcodTest 'acquisition exception and actual-session mismatch fail before engine actions' {
        $request=New-CcodControllerRequest
        $exceptionEvents=[Collections.Generic.List[string]]::new();$exceptionLogs=[Collections.Generic.List[string]]::new();$failure=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$exceptionEvents.Add("enter:$Kind");throw "C:\private\acl.sddl`n--token hunter2"}.GetNewClosure()
            ReadJournal={param($Path)$exceptionEvents.Add('journal')}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$exceptionEvents.Add('engine')}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)$exceptionLogs.Add($Line)}.GetNewClosure()
        }
        Assert-CcodEqual 'enter:AccountTransition' ($exceptionEvents -join ',') 'acquisition exception cannot reach journal or engine'
        Assert-CcodEqual 'CCOD_KERNEL_OPEN_FAILED' $failure.Result.error.code 'unrecognized acquisition exception maps to one stable kernel code'
        Assert-CcodEqual 'LeaseAcquire' $failure.Result.stage 'acquisition exception remains in lease stage'
        Assert-CcodEqual 1 $exceptionLogs.Count 'acquisition exception writes one bounded diagnostic'
        Assert-CcodTrue ((($failure.Result|ConvertTo-Json -Depth 16 -Compress)+$exceptionLogs[0]) -cnotmatch 'private|hunter2|sddl') 'acquisition exception is redacted from framing and log'

        $mismatchEvents=[Collections.Generic.List[string]]::new();$mismatch=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            GetIdentity={ [pscustomobject][ordered]@{UserSid='S-1-5-21-111-222-333-1001';SessionId=[int]2} }
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$mismatchEvents.Add('enter');throw 'must not acquire'}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$mismatchEvents.Add('engine')}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodEqual 0 $mismatchEvents.Count 'request session mismatch has no lease or engine action'
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $mismatch.Result.error.code 'actual session mismatch is stable request invalid'
        Assert-CcodEqual 'InputValidation' $mismatch.Result.stage 'session mismatch is input validation'

        foreach($case in @(
            @{Name='pid';Live=[pscustomobject][ordered]@{Pid=[int]12;CreationTimeUtc='2030-02-03T03:00:00.0000000Z';SessionId=[int]1}},
            @{Name='creation';Live=[pscustomobject][ordered]@{Pid=[int]11;CreationTimeUtc='2030-02-03T03:00:01.0000000Z';SessionId=[int]1}}
        )){
            $authorityEvents=[Collections.Generic.List[string]]::new()
            $authority=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                GetSupervisorProcess={param($ProcessId)$case.Live}.GetNewClosure()
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$authorityEvents.Add('enter');throw 'must not acquire'}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)$authorityEvents.Add('engine');throw 'must not invoke'}.GetNewClosure()
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual 0 $authorityEvents.Count "$($case.Name) mismatch has no lease or engine action"
            Assert-CcodEqual 'CCOD_REQUEST_INVALID' $authority.Result.error.code "$($case.Name) mismatch is stable request invalid"
            Assert-CcodEqual 'InputValidation' $authority.Result.stage "$($case.Name) mismatch is input validation"
        }
    }

    Invoke-CcodTest 'stopwatch initialization failure is correlated redacted and framed once' {
        $request=New-CcodControllerRequest;$events=[Collections.Generic.List[string]]::new();$writes=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$escaped=$null;$run=$null
        try{
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                StartStopwatch={throw "C:\private\clock-init`n--token hunter2"};EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add('enter');throw 'must not acquire'}.GetNewClosure();ReadJournal={param($Path)$events.Add('journal')}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine')}.GetNewClosure()
                WriteResult={param($Path,$Value)$writes.Add(($Value|ConvertTo-Json -Depth 16 -Compress))}.GetNewClosure();WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
            }
        }catch{$escaped=$_}
        Assert-CcodEqual $null $escaped 'stopwatch adapter failure never escapes controller framing'
        Assert-CcodEqual 0 $events.Count 'clock initialization failure occurs before leases journal or engine'
        Assert-CcodEqual 'CCOD_KERNEL_OPEN_FAILED' $run.Result.error.code 'clock initialization uses one stable lease code'
        Assert-CcodEqual 'LeaseAcquire' $run.Result.stage 'clock initialization is a lease-stage failure'
        Assert-CcodEqual $request.transactionId $run.Result.transactionId 'clock initialization retains exact correlation'
        Assert-CcodEqual 1 $writes.Count 'clock initialization writes one atomic error result'
        Assert-CcodEqual 1 $stdout.Count 'clock initialization emits one stdout frame'
        Assert-CcodEqual $writes[0] $stdout[0] 'clock initialization file/stdout frames match'
        Assert-CcodEqual 1 $run.ExitCode 'clock initialization failure is unsafe'
        Assert-CcodTrue ((($run.Result|ConvertTo-Json -Depth 16 -Compress)+$stdout[0]) -cnotmatch 'private|hunter2|clock-init') 'clock initialization secret is redacted'
    }

    Invoke-CcodTest 'rejects every malformed exact lease before journal engine or cleanup dereference' {
        $cases=@('Minimal','Dictionary','MissingField','ExtraField','WrongOrder','ScriptProperty','SchemaType','SchemaValue','NameMismatch','NameType','KindCase','KindMismatch','KindType','OutcomeCase','OutcomeUnknown','OutcomeType','CreatedNewType','AbandonedType','AcquiredHandleNull','AcquiredHandleType','AcquiredHandleClosed','AcquiredOwnerType','AcquiredOwnerMismatch','AcquiredOwnerZero','AcquiredReleased','ReleasedType','TimeoutAbandoned','TimeoutHandle','TimeoutOwner','TimeoutNotReleased')
        foreach($case in $cases){
            $lease=New-CcodMalformedControllerTestLease $case;$events=[Collections.Generic.List[string]]::new();$writes=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$escaped=$null;$run=$null
            try{
                try{
                    $run=Invoke-CcodLeasedTestController -Request (New-CcodControllerRequest) -Paths $paths -ResultPath $resultPath -Adapters @{
                        EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");$lease}.GetNewClosure()
                        ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");throw 'invalid lease must never be released'}.GetNewClosure()
                        ReadJournal={param($Path)$events.Add('journal');throw 'invalid lease must never reach journal'}.GetNewClosure()
                        EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');throw 'invalid lease must never reach engine'}.GetNewClosure()
                        WriteResult={param($Path,$Value)$writes.Add(($Value|ConvertTo-Json -Depth 16 -Compress))}.GetNewClosure()
                        WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
                    }
                }catch{$escaped=$_}
                Assert-CcodEqual $null $escaped "$case malformed lease never escapes cleanup framing"
                Assert-CcodEqual 'enter:AccountTransition' ($events -join ',') "$case stops before journal engine or release"
                Assert-CcodEqual 'CCOD_KERNEL_LEASE_INVALID' $run.Result.error.code "$case maps to the stable invalid-lease code"
                Assert-CcodEqual 'LeaseAcquire' $run.Result.stage "$case remains a lease-acquire failure"
                Assert-CcodEqual 1 $writes.Count "$case persists one unsafe result"
                Assert-CcodEqual 1 $stdout.Count "$case emits one stdout frame"
                Assert-CcodEqual $writes[0] $stdout[0] "$case file and stdout frames match"
                Assert-CcodEqual 1 $run.ExitCode "$case exits unsafe"
            }finally{[void](Close-CcodControllerTestLease $lease)}
        }
    }

    Invoke-CcodTest 'a malformed delegated session lease releases only the reentered account lease' {
        $account=New-CcodControllerTestLease AccountTransition;$session=[pscustomobject][ordered]@{Kind='Transition'};$events=[Collections.Generic.List[string]]::new();$escaped=$null;$run=$null
        try{
            try{
                $run=Invoke-CcodLeasedTestController -Request (New-CcodControllerRequest) -Paths $paths -ResultPath $resultPath -Adapters @{
                    EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");if($Kind-ceq'AccountTransition'){$account}else{$session}}.GetNewClosure()
                    ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");Close-CcodControllerTestLease $Lease}.GetNewClosure()
                    ReadJournal={param($Path)$events.Add('journal');throw 'invalid session lease must never reach journal'}.GetNewClosure()
                    EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');throw 'invalid session lease must never reach engine'}.GetNewClosure()
                    WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
                }
            }catch{$escaped=$_}
            Assert-CcodEqual $null $escaped 'malformed session lease cannot break cleanup framing'
            Assert-CcodEqual 'enter:AccountTransition,enter:Transition,exit:AccountTransition' ($events -join ',') 'invalid delegated session lease releases the validated account lease once'
            Assert-CcodEqual 'CCOD_KERNEL_LEASE_INVALID' $run.Result.error.code 'malformed session lease maps to the stable invalid-lease code'
            Assert-CcodEqual 1 $run.ExitCode 'malformed session lease exits unsafe'
        }finally{[void](Close-CcodControllerTestLease $account)}
    }

    Invoke-CcodTest 'journal callback IDs use only the six exact transition errors with no callback data' {
        $stableIds=@('CCOD_TRANSITION_INVALID','CCOD_TRANSITION_CONFLICT','CCOD_TRANSITION_STAGE_INVALID','CCOD_TRANSITION_COMPLETION_INVALID','CCOD_TRANSITION_ARCHIVE_FAILED','CCOD_TRANSITION_RECEIPT_INVALID')
        $cases=@($stableIds|ForEach-Object{[pscustomobject]@{Id=$_;Expected=$_}})+@(
            [pscustomobject]@{Id='CCOD_TRANSITION_INVALID_LOOKALIKE';Expected='CCOD_TRANSITION_INVALID'},
            [pscustomobject]@{Id='CCOD_TRANSITION_ARCHIVE_FAILED_EVIL';Expected='CCOD_TRANSITION_INVALID'},
            [pscustomobject]@{Id='EVIL_JOURNAL_CALLBACK';Expected='CCOD_TRANSITION_INVALID'}
        )
        foreach($case in $cases){
            $request=New-CcodControllerRequest;$forgedId=$case.Id;$engineCalls=[Collections.Generic.List[string]]::new();$logs=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new()
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                ReadJournal={
                    param($Path)
                    $exception=[InvalidOperationException]::new("C:\private\journal-callback`n--token hunter2")
                    throw [Management.Automation.ErrorRecord]::new($exception,$forgedId,[Management.Automation.ErrorCategory]::InvalidData,'C:\private\journal-target')
                }.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)$engineCalls.Add($Action);throw 'journal failure must prevent engine'}.GetNewClosure()
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
                WriteLog={param($Path,$Line)$logs.Add($Line)}.GetNewClosure()
            }
            Assert-CcodEqual 0 $engineCalls.Count "$($case.Id) cannot reach engine"
            Assert-CcodEqual $case.Expected $run.Result.error.code "$($case.Id) uses only the exact six-ID allowlist"
            Assert-CcodEqual 'JournalPreflight' $run.Result.stage "$($case.Id) stays in journal preflight"
            Assert-CcodEqual $request.transactionId $run.Result.transactionId "$($case.Id) preserves correlation"
            Assert-CcodEqual 1 $stdout.Count "$($case.Id) emits one stdout frame"
            Assert-CcodEqual 1 $logs.Count "$($case.Id) emits one bounded diagnostic"
            Assert-CcodEqual $case.Expected (($logs[0]|ConvertFrom-Json).code) "$($case.Id) diagnostic contains only the normalized code"
            Assert-CcodTrue ((($run.Result|ConvertTo-Json -Depth 16 -Compress)+$stdout[0]+$logs[0]) -cnotmatch 'private|hunter2|journal-target|LOOKALIKE|EVIL_JOURNAL') "$($case.Id) exposes no callback message target or FQID"
            Assert-CcodEqual 1 $run.ExitCode "$($case.Id) exits unsafe"
        }
    }

    Invoke-CcodTest 'active journal requires a fresh lifecycle step for every schema-v2 action' {
        $active=[pscustomobject]@{transactionId='1b2c5c27-e6e3-4ae4-a876-a59418519d41';stage='OrdinaryStopped'}
        foreach($action in @('Inspect','Apply','RepairRenderer')){
            $calls=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action $action
            $blocked=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                ReadJournal={param($Path)$active}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$calls.Add($Action);throw 'must not invoke'}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual 0 $calls.Count "$action cannot bypass active journal"
            Assert-CcodEqual 'CCOD_TRANSITION_REPLAY_REQUIRED' $blocked.Result.error.code "$action returns stable replay requirement"
            Assert-CcodEqual 'ReplayRequired' $blocked.Result.stage "$action replay stage"
        }
    }

    Invoke-CcodTest 'abandonment logs one exact warning then replays or invokes once without reacquiring' {
        foreach($withJournal in @($false)){
            $events=[Collections.Generic.List[string]]::new();$logs=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action $(if($withJournal){'Recover'}else{'Apply'})
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind Acquired ($Kind -ceq 'Transition')}.GetNewClosure()
                ReadJournal={param($Path)$events.Add('journal');if($withJournal){[pscustomobject]@{transactionId='1b2c5c27-e6e3-4ae4-a876-a59418519d41';stage='SpecialStarted'}}else{$null}}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)$events.Add("engine:$Action");New-CcodControllerResult $Action $Request.transactionId $(if($Action -ceq 'Recover'){'Recovered'}else{'Activated'})}.GetNewClosure()
                WriteLog={param($Path,$Line)$logs.Add($Line)}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual 2 @($events|Where-Object{$_ -like 'enter:*'}).Count 'delegated operation proves the account handoff before the session lease'
            Assert-CcodEqual 1 @($events|Where-Object{$_ -like 'engine:*'}).Count 'abandoned path invokes exactly once'
            Assert-CcodEqual 1 $logs.Count 'one warning is emitted even if one of two leases is abandoned'
            $record=$logs[0]|ConvertFrom-Json
            Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code' (($record.PSObject.Properties.Name)-join ',') 'warning record has exact bounded fields'
            Assert-CcodEqual 'LeaseAcquire' $record.stage 'warning stage'
            Assert-CcodEqual 'CCOD_TRANSITION_ABANDONED' $record.code 'warning code'
        }
    }

    Invoke-CcodTest 'engine and result-write exceptions release both delegated leases exactly once' {
        foreach($failurePoint in @('Engine','Write')){
            $releases=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest
            $adapters=@{
                ExitMutex={param($Lease)$releases.Add($Lease.Kind);Close-CcodControllerTestLease $Lease}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)if($failurePoint -ceq 'Engine'){throw 'engine secret path C:\private\x'}else{New-CcodControllerResult $Action $Request.transactionId}}.GetNewClosure()
                WriteResult={param($Path,$Value)if($failurePoint -ceq 'Write'){throw 'write secret token hunter2'}}.GetNewClosure()
                WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
            }
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters $adapters
            Assert-CcodEqual 'Transition,AccountTransition' ($releases -join ',') "$failurePoint releases session then account exactly once"
            Assert-CcodEqual 1 $run.ExitCode "$failurePoint exits unsafe"
            Assert-CcodTrue (($run.Result|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'private|hunter2|secret') "$failurePoint public framing is sanitized"
        }
    }

    Invoke-CcodTest 'delegated lease release failure corrects the durable result' {
        $request=New-CcodControllerRequest;$leases=[Collections.Generic.List[object]]::new();$events=[Collections.Generic.List[string]]::new();$writes=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$logs=[Collections.Generic.List[string]]::new()
        try{
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$lease=New-CcodControllerTestLease $Kind;$leases.Add($lease);$lease}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId Inspected}.GetNewClosure()
                WriteResult={param($Path,$Value)$events.Add('write');$writes.Add(($Value|ConvertTo-Json -Depth 16 -Compress))}.GetNewClosure()
                ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");throw "C:\private\release-$($Lease.Kind)`n--token hunter2"}.GetNewClosure()
                WriteStdout={param($Line)$events.Add('stdout');$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
                WriteLog={param($Path,$Line)$logs.Add($Line)}.GetNewClosure()
            }
            Assert-CcodEqual 'write,exit:Transition,exit:AccountTransition,write,stdout' ($events -join ',') 'success is corrected after each delegated release is attempted'
            Assert-CcodEqual 2 $writes.Count 'release failure overwrites the earlier durable success with one corrected result'
            Assert-CcodEqual $false (($writes[0]|ConvertFrom-Json).ok) 'the initial under-lease write is the unsafe provisional'
            Assert-CcodEqual 1 $stdout.Count 'release failure still emits exactly one stdout frame'
            Assert-CcodEqual $writes[1] $stdout[0] 'the corrected durable result and stdout are identical'
            Assert-CcodEqual $writes[1] ($run.Result|ConvertTo-Json -Depth 16 -Compress) 'the returned result is the corrected durable result'
            Assert-CcodEqual 'schemaVersion,action,ok,outcome,safeState,stage,transactionId,package,source,special,probes,recovery,error,logFile' (($run.Result.PSObject.Properties.Name)-join ',') 'release correction retains the exact 14-field result contract'
            Assert-CcodEqual $false $run.Result.ok 'release failure cannot claim success'
            Assert-CcodEqual 'Error' $run.Result.outcome 'release failure has an unsafe outcome'
            Assert-CcodEqual 'LeaseRelease' $run.Result.stage 'release failure has the exact stage'
            Assert-CcodEqual 'CCOD_KERNEL_RELEASE_FAILED' $run.Result.error.code 'release failure has the stable code'
            Assert-CcodEqual $request.transactionId $run.Result.transactionId 'release failure preserves correlation'
            Assert-CcodEqual 1 $run.ExitCode 'release failure exits unsafe'
            Assert-CcodEqual 1 $logs.Count 'release failure emits one bounded diagnostic'
            Assert-CcodTrue ((($writes -join '')+($stdout -join '')+($logs -join '')) -cnotmatch 'private|hunter2|release-Transition|release-AccountTransition') 'release callback secrets never enter durable public or diagnostic framing'
        }finally{foreach($lease in $leases){[void](Close-CcodControllerTestLease $lease)}}
    }

    Invoke-CcodTest 'keeps every two-phase write and release failure window durably unsafe' {
        foreach($mode in @('ProvisionalWriteFailure','FinalWriteFailure','ReleaseFailure','ReleaseAndFinalWriteFailure')){
            $request=New-CcodControllerRequest;$leases=[Collections.Generic.List[object]]::new();$releases=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$state=[pscustomobject]@{WriteCount=0;Durable=$null}
            try{
                $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                    EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$lease=New-CcodControllerTestLease $Kind;$leases.Add($lease);$lease}.GetNewClosure()
                    EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId Inspected}.GetNewClosure()
                    WriteResult={
                        param($Path,$Value)
                        $state.WriteCount++
                        if(($mode -ceq 'ProvisionalWriteFailure' -and $state.WriteCount -eq 1) -or (($mode -ceq 'FinalWriteFailure' -or $mode -ceq 'ReleaseAndFinalWriteFailure') -and $state.WriteCount -eq 2)){throw "C:\private\write-window`n--token hunter2"}
                        $state.Durable=$Value|ConvertTo-Json -Depth 16 -Compress
                    }.GetNewClosure()
                    ExitMutex={param($Lease)$releases.Add($Lease.Kind);if($mode.StartsWith('Release',[StringComparison]::Ordinal)){throw "C:\private\release-window`n--token hunter2"};Close-CcodControllerTestLease $Lease}.GetNewClosure()
                    WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
                }
                Assert-CcodEqual 2 $state.WriteCount "$mode attempts one provisional and one post-release final write"
                Assert-CcodEqual 'Transition,AccountTransition' ($releases -join ',') "$mode attempts both delegated releases exactly once"
                Assert-CcodTrue ($null -ne $state.Durable) "$mode leaves an atomic durable frame"
                $durable=$state.Durable|ConvertFrom-Json
                Assert-CcodEqual $false $durable.ok "$mode never leaves durable success"
                Assert-CcodEqual 'Error' $durable.outcome "$mode durable frame is explicitly unsafe"
                Assert-CcodEqual $request.transactionId $durable.transactionId "$mode durable frame remains correlated"
                Assert-CcodEqual 1 $stdout.Count "$mode emits one stdout frame"
                Assert-CcodEqual $false (($stdout[0]|ConvertFrom-Json).ok) "$mode stdout never claims success"
                Assert-CcodEqual 1 $run.ExitCode "$mode exits unsafe"
                $expectedCode=if($mode -ceq 'ReleaseFailure'){'CCOD_KERNEL_RELEASE_FAILED'}else{'CCOD_CONTROLLER_RESULT_WRITE_FAILED'}
                Assert-CcodEqual $expectedCode $run.Result.error.code "$mode returns the stable final failure code"
                Assert-CcodTrue (($state.Durable+$stdout[0]) -cnotmatch 'private|hunter2|write-window|release-window') "$mode public framing is sanitized"
            }finally{foreach($lease in $leases){[void](Close-CcodControllerTestLease $lease)}}
        }
    }

    Invoke-CcodTest 'a true release return without the exact released lease mutation cannot publish success' {
        $request=New-CcodControllerRequest;$leases=[Collections.Generic.List[object]]::new();$releases=[Collections.Generic.List[string]]::new();$writes=[Collections.Generic.List[string]]::new()
        try{
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$lease=New-CcodControllerTestLease $Kind;$leases.Add($lease);$lease}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId Inspected}.GetNewClosure()
                ExitMutex={param($Lease)$releases.Add($Lease.Kind);$true}.GetNewClosure()
                WriteResult={param($Path,$Value)$writes.Add(($Value|ConvertTo-Json -Depth 16 -Compress))}.GetNewClosure();WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
            }
            Assert-CcodEqual 'Transition,AccountTransition' ($releases -join ',') 'the deceptive delegated release callbacks are each attempted once'
            Assert-CcodEqual 2 $writes.Count 'deceptive release return retains provisional then publishes one unsafe correction'
            Assert-CcodEqual $false (($writes[0]|ConvertFrom-Json).ok) 'pre-release provisional is unsafe'
            Assert-CcodEqual $false (($writes[1]|ConvertFrom-Json).ok) 'post-release correction is unsafe'
            Assert-CcodEqual 'CCOD_KERNEL_RELEASE_FAILED' $run.Result.error.code 'missing released-state mutation is a stable release failure'
            Assert-CcodEqual 'LeaseRelease' $run.Result.stage 'missing released-state mutation uses the exact release stage'
            Assert-CcodEqual 1 $run.ExitCode 'missing released-state mutation exits unsafe'
        }finally{foreach($lease in $leases){[void](Close-CcodControllerTestLease $lease)}}
    }

    Invoke-CcodTest 'clock or warning-log failure cannot bypass release and stable framing' {
        foreach($mode in @('Diagnostic','AbandonedWarning')){
            $releases=[Collections.Generic.List[string]]::new();$engineCalls=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action $(if($mode -ceq 'Diagnostic'){'Inspect'}else{'Apply'})
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                UtcNow={throw "C:\private\clock`n--token hunter2"}
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)New-CcodControllerTestLease $Kind Acquired ($mode -ceq 'AbandonedWarning' -and $Kind -ceq 'AccountTransition')}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)$engineCalls.Add($Action);if($mode -ceq 'Diagnostic'){throw 'engine failed'}else{New-CcodControllerResult $Action $Request.transactionId Activated}}.GetNewClosure()
                ExitMutex={param($Lease)$releases.Add($Lease.Kind);Close-CcodControllerTestLease $Lease}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)throw 'log unavailable'}
            }
            Assert-CcodEqual 'Transition,AccountTransition' ($releases -join ',') "$mode still releases both delegated leases"
            Assert-CcodEqual 1 $engineCalls.Count "$mode retains the intended single engine dispatch"
            Assert-CcodTrue (($run.Result|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'private|hunter2|clock') "$mode returns bounded public framing"
        }
    }

    Invoke-CcodTest 'preserves correlation and maps the exact safe exit-code matrix including Closed' {
        foreach($outcome in @('Activated','Inspected','NoAction','Recovered','Closed','Error')){
            $stdout=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -TransactionId 'f81b6259-8e99-45fb-b557-c5292f05dfa3'
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EngineInvoker={param($Action,$Request,$Paths)if($outcome -ceq 'Error'){[pscustomobject][ordered]@{schemaVersion=1;action=$Action;ok=$false;outcome='Error';safeState='Error';stage='Failed';transactionId=$Request.transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=[pscustomobject][ordered]@{code='TEST';stage='Failed';message='failed'};logFile=$null}}else{New-CcodControllerResult $Action $Request.transactionId $outcome}}.GetNewClosure()
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
            }
            Assert-CcodEqual $request.transactionId $run.Result.transactionId "$outcome keeps request correlation"
            $expected=if($outcome -ceq 'Error'){1}else{0};Assert-CcodEqual $expected $run.ExitCode "$outcome exit code"
        }
    }

    Invoke-CcodTest 'returns stable framing errors for malformed engine output or atomic result failure' {
        $request=New-CcodControllerRequest
        $malformed=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{EngineInvoker={param($Action,$Request,$Paths)[pscustomobject]@{ok=$true}};WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}}
        Assert-CcodEqual 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' $malformed.Result.error.code 'malformed engine output fails closed'

        $stdout=[Collections.Generic.List[string]]::new();$writeFailure=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)throw 'disk failed'};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' $writeFailure.Result.error.code 'atomic result failure has a stable code'
        Assert-CcodEqual 1 $writeFailure.ExitCode 'result write failure exits nonzero'
        Assert-CcodEqual 1 $stdout.Count 'result write failure still emits one machine-readable error line'

        $secret="C:\private\request.json`n--token hunter2`ncommand.exe --password=swordfish";$logs=[Collections.Generic.List[string]]::new()
        $leak=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)throw $secret}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            WriteLog={param($Path,$Message)$logs.Add($Message)}.GetNewClosure()
        }
        Assert-CcodEqual 'The session controller failed safely. See the session log for details.' $leak.Result.error.message 'controller public error is fixed and generic'
        Assert-CcodEqual $paths.SessionLogPath $leak.Result.logFile 'controller returns a safe log reference after diagnostic persistence'
        Assert-CcodEqual 1 $logs.Count 'controller failure writes one allowlisted diagnostic'
        Assert-CcodTrue ($logs[0] -cnotmatch 'private|hunter2|swordfish|command\.exe|[\r\n]') 'controller diagnostic never contains raw exception data'
        $logRecord=$logs[0]|ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code' (($logRecord.PSObject.Properties.Name)-join ',') 'controller diagnostic uses the fixed allowlist'
        Assert-CcodEqual 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' $logRecord.code 'controller diagnostic retains only the stable error code'

        $missingAction=[pscustomobject]@{transactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda'};$missingStdout=[Collections.Generic.List[string]]::new()
        $missing=Invoke-CcodLeasedTestController -Request $missingAction -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={throw 'must not dispatch'};WriteResult={param($Path,$Value)};WriteStdout={param($Line)$missingStdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)};WriteLog={param($Path,$Message)}
        }
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $missing.Result.error.code 'a missing action is rejected before lease or engine dispatch'
        Assert-CcodEqual 1 $missingStdout.Count 'a malformed request cannot break one-line controller framing'

        $poison="C:\secret\device-key.json`n--token hunter2";$poisonLogs=[Collections.Generic.List[string]]::new()
        $poisonedRequest=[pscustomobject]@{action=$poison;transactionId="bad`n--password swordfish"}
        $poisoned=Invoke-CcodLeasedTestController -Request $poisonedRequest -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={throw 'must not dispatch'};WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Message)$poisonLogs.Add($Message)}.GetNewClosure()
        }
        Assert-CcodEqual $null $poisoned.Result.action 'invalid action metadata is not echoed into the public result'
        Assert-CcodEqual $null $poisoned.Result.transactionId 'noncanonical transaction metadata is not echoed into the public result'
        Assert-CcodTrue ((($poisoned.Result|ConvertTo-Json -Depth 16 -Compress)+($poisonLogs -join '')) -cnotmatch 'secret|hunter2|swordfish|device-key') 'malformed request metadata cannot bypass public and log redaction'
    }

    Invoke-CcodTest 'constructs direct manual input as the same strict fenced schema-v2 request' {
        $identity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        $request=New-CcodManualControllerRequest -Action Apply -RuntimeId runtime-1 -SupervisorIdentity $identity -ExistingOnly $false -RendererPort $null -MainPort 41002 -TimeoutMilliseconds 30000 -RestartOrdinary $true -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        Assert-CcodEqual 'schemaVersion,action,transactionId,runtimeId,runtimeGeneration,leaseEpoch,ownerIdentity,supervisorIdentity,source,existingOnly,rendererPort,mainPort,timeoutMilliseconds,restartOrdinary' (($request.PSObject.Properties.Name)-join ',') 'manual request has exact strict field order'
        Assert-CcodEqual 2 $request.schemaVersion 'manual request uses the fenced controller schema'
        Assert-CcodEqual $null $request.source 'manual Start does not invent a source snapshot'
        Assert-CcodEqual $false $request.existingOnly 'manual Start can authorize closed-app activation'
        $result=Invoke-CcodApplySession -Request $request -Paths $paths -Adapters @{ReadState={throw 'expected after validation'}}
        Assert-CcodTrue ($result.error.code -cne 'CCOD_REQUEST_INVALID') 'manual request reaches the same engine contract without a looser translation'
    }

    Invoke-CcodTest 'rejects manual construction and strict request-file input without a LifecycleWorker delegation' {
        $identity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        $manual=New-CcodManualControllerRequest -Action Inspect -RuntimeId runtime-1 -SupervisorIdentity $identity -ExistingOnly $true -RendererPort $null -MainPort $null -TimeoutMilliseconds 30000 -RestartOrdinary $true -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        $requestFile=Join-Path $root 'leased-request.json';Write-CcodAtomicJson -Path $requestFile -Value (New-CcodControllerRequest -TransactionId 'f81b6259-8e99-45fb-b557-c5292f05dfa3');$fromFile=Read-CcodStrictJson -Path $requestFile -ExpectedSchema 2 -Kind 'session controller request'
        foreach($case in @($manual,$fromFile)){
            $events=[Collections.Generic.List[string]]::new()
            $run=Invoke-CcodLeasedTestController -Request $case -Paths $paths -ResultPath $resultPath -Adapters @{
                GetDelegatedOwnership={$null};EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$events.Add("engine:$Action");New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual '' (($events|Where-Object{$_ -like 'enter:*' -or $_ -like 'engine:*'})-join ',') 'both external input origins reach neither mutex nor engine'
            Assert-CcodEqual 'CCOD_REQUEST_INVALID' $run.Result.error.code 'both strict input origins require an execution-local worker delegation'
            Assert-CcodEqual 1 $run.ExitCode 'both external input origins fail closed'
        }
    }

    Invoke-CcodTest 'real LifecycleWorker controller delegation runs under held ownership and rejects a stale epoch' {
        $integration=Join-Path $root 'delegated-cross-process';$install=Join-Path $integration 'install';$state=Join-Path $install 'state';$workers=Join-Path $state 'workers'
        [IO.Directory]::CreateDirectory($workers)|Out-Null
        Write-CcodAtomicJson -Path (Join-Path $install 'active.json') -Value ([ordered]@{schemaVersion=2;activeRuntime='runtime-1';previousRuntime=$null;generation=[UInt64]1;updatedAtUtc='2030-02-03T04:05:06.0000000Z'})
        Write-CcodAtomicJson -Path (Join-Path $state 'transition.json') -Value ([ordered]@{schemaVersion=1;activeTransaction=$null})
        $process=[Diagnostics.Process]::GetCurrentProcess();$windows=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$owner=[pscustomobject][ordered]@{pid=[int]$process.Id;creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o')};$sessionId=[int]$process.SessionId;$userSid=$windows.User.Value}finally{$process.Dispose();$windows.Dispose()}
        $ownership=Enter-CcodLifecycleOwnership -InstallRoot ([IO.Path]::GetFullPath($install)) -RuntimeId runtime-1 -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 5000
        $helper=Join-Path $integration 'delegated-worker.ps1'
        $workerRuntimePath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\persistence\modules\WorkerRuntime.psm1'));$controllerPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\persistence\SessionController.ps1'));$lifecycleWorkerPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\persistence\LifecycleWorker.ps1'));$workersRoot=[IO.Path]::GetFullPath($workers);$installRoot=[IO.Path]::GetFullPath($install);$controllerPaths=New-CcodControllerPaths $integration
        $helperBody=@'
[CmdletBinding()]
param([string]$RequestPath,[string]$ResultPath)
$ErrorActionPreference='Stop'
$summaryResultPath=$ResultPath
trap{[IO.File]::WriteAllText($summaryResultPath,([pscustomobject][ordered]@{error=$_.Exception.Message;id=$_.FullyQualifiedErrorId}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));exit 0}
[IO.File]::WriteAllText($summaryResultPath,'{"entered":true}',[Text.UTF8Encoding]::new($false))
$config=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
. $config.lifecycleWorkerPath
. $config.controllerPath
$closure=@('src/check-package.mjs','src/runtime/orchestrator.js','src/runtime/main-payload.js','src/persistence/LifecycleWorker.ps1','src/persistence/SessionController.ps1','src/persistence/modules/CompatibilityProbe.psm1','src/persistence/modules/PersistenceIO.psm1','src/persistence/modules/StateStore.psm1','src/persistence/modules/ProcessControl.psm1','src/persistence/modules/RendererIntegration.psm1','src/persistence/modules/TransitionJournal.psm1','src/persistence/modules/SessionEngine.psm1','src/persistence/modules/RuntimeManifest.psm1','src/persistence/modules/LifecycleEpoch.psm1','src/persistence/modules/KernelObjects.psm1','src/persistence/modules/WorkerRuntime.psm1')
$manifest=[pscustomobject][ordered]@{schemaVersion=1;projectVersion='2.5.0';runtimeId='runtime-1';files=@($closure|ForEach-Object{[pscustomobject][ordered]@{path=$_;length=1;sha256=('a'*64)}})}
$context=[pscustomobject][ordered]@{InstallRoot=$config.installRoot;RuntimeRoot=(Join-Path $config.installRoot 'runtime\runtime-1');RuntimeId='runtime-1';RuntimeGeneration=[UInt64]1;WorkerPath=$config.lifecycleWorkerPath;WorkersRoot=$config.workersRoot;Manifest=$manifest}
$runs=[Collections.Generic.List[object]]::new();$counts=[pscustomobject]@{Controller=0;Last=$null}
foreach($action in @($config.actions)){
    $transactionId=[guid]::NewGuid().ToString('D');$workerRequest=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$transactionId;action=[string]$action;runtimeId='runtime-1';runtimeGeneration=[UInt64]1;leaseEpoch=[UInt64]$config.epoch;ownerIdentity=[pscustomobject][ordered]@{pid=[int]$config.ownerPid;creationTimeUtc=[string]$config.ownerCreated};notBeforeUtc='2030-02-03T04:05:10.0000000Z';timeoutMilliseconds=700}
    $workerRequestPath=[IO.Path]::GetFullPath((Join-Path $config.workersRoot ("lifecycle-$transactionId.request.json")));$workerResultPath=[IO.Path]::GetFullPath((Join-Path $config.workersRoot ("lifecycle-$transactionId.result.json")))
    [IO.File]::WriteAllText($workerRequestPath,($workerRequest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $workerAdapters=@{
        GetScriptPath={$config.lifecycleWorkerPath}.GetNewClosure();GetBootstrapContext={[pscustomobject][ordered]@{InstallRoot=$config.installRoot;WorkersRoot=$config.workersRoot}}.GetNewClosure();ResolveRuntime={param($Path,$Runtime,$Generation)$context}.GetNewClosure();ReadRequest={param($Path)Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
        AssertFence={param($Context,$Request)if($config.forceWorkerFence){return $true};$receipt=[pscustomobject][ordered]@{schemaVersion=1;lease=[pscustomobject][ordered]@{Released=$false};epoch=[UInt64]$Request.leaseEpoch;runtimeId=$Request.runtimeId;runtimeGeneration=[UInt64]$Request.runtimeGeneration;ownerIdentity=$Request.ownerIdentity;released=$false};Assert-CcodLifecycleFence -InstallRoot $Context.InstallRoot -Ownership $receipt}.GetNewClosure()
        InvokeController={
            param($ActionName,$RequestValue,$ContextValue,$DelegationValue);$counts.Controller++
            $controllerRequest=[pscustomobject][ordered]@{schemaVersion=2;action=$ActionName;transactionId=$RequestValue.transactionId;runtimeId=$RequestValue.runtimeId;runtimeGeneration=[UInt64]$RequestValue.runtimeGeneration;leaseEpoch=[UInt64]$RequestValue.leaseEpoch;ownerIdentity=$RequestValue.ownerIdentity;supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$RequestValue.ownerIdentity.pid;creationTimeUtc=$RequestValue.ownerIdentity.creationTimeUtc;sessionId=[string]$config.sessionId};source=$null;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=700;restartOrdinary=($ActionName-cne'Close')}
            $controllerAdapters=Get-CcodControllerAdapters @{
                EngineInvoker={param($InnerAction,$InnerRequest,$InnerPaths,$EngineAdapters)$outcome=if($InnerAction-ceq'Close'){'Closed'}elseif($InnerAction-ceq'Apply'){'NoAction'}else{'Inspected'};$safe=if($InnerAction-ceq'Close'){'Closed'}else{'NoCodex'};[pscustomobject][ordered]@{schemaVersion=1;action=$InnerAction;ok=$true;outcome=$outcome;safeState=$safe;stage='Completed';transactionId=$InnerRequest.transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=$null;logFile=$null}}
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
                GetDelegatedOwnership={$DelegationValue}.GetNewClosure()
            }
            $controllerRun=Invoke-CcodSessionController -Request $controllerRequest -Paths $config.controllerPaths -ResultPath $workerResultPath -Adapters $controllerAdapters;$counts.Last=$controllerRun.Result
            $controllerRun.Result
        }.GetNewClosure()
        WriteResult={param($Path,$Value)Write-CcodAtomicJson -Path $Path -Value $Value};WriteStdout={param($Line)};WriteStderr={param($Line)}
    }
    $run=Invoke-CcodLifecycleWorker -RequestPath $workerRequestPath -ResultPath $workerResultPath -Adapters $workerAdapters
    $runs.Add([pscustomobject][ordered]@{action=$action;exitCode=[int]$run.ExitCode;errorCode=$(if($null-eq$run.Result.error){$null}else{$run.Result.error.code});controllerOk=$(if($null-eq$counts.Last){$null}else{$counts.Last.ok});controllerError=$(if($null-eq$counts.Last-or$null-eq$counts.Last.error){$null}else{$counts.Last.error.code})})
}
[IO.File]::WriteAllText($summaryResultPath,([pscustomobject][ordered]@{runs=$runs.ToArray();controllerCalls=$counts.Controller}|ConvertTo-Json -Depth 10 -Compress),[Text.UTF8Encoding]::new($false))
'@
        [IO.File]::WriteAllText($helper,$helperBody,[Text.UTF8Encoding]::new($false))
        $helperTokens=$null;$helperErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($helper,[ref]$helperTokens,[ref]$helperErrors);Assert-CcodEqual 0 @($helperErrors).Count 'delegated helper parses before process launch'
        function Invoke-CcodDelegatedChild($OwnerReceipt,[UInt64]$Epoch,[bool]$ForceWorkerFence,[string[]]$Actions,[string]$Leaf){
            $configPath=Join-Path $integration ($Leaf+'.request.json');$summaryPath=Join-Path $integration ($Leaf+'.result.json')
            Write-CcodAtomicJson -Path $configPath -Value ([ordered]@{epoch=$Epoch;ownerPid=[int]$OwnerReceipt.ownerIdentity.pid;ownerCreated=$OwnerReceipt.ownerIdentity.creationTimeUtc;sessionId=$sessionId;forceWorkerFence=$ForceWorkerFence;actions=$Actions;controllerPath=$controllerPath;lifecycleWorkerPath=$lifecycleWorkerPath;workersRoot=$workersRoot;installRoot=$installRoot;controllerPaths=$controllerPaths})
            $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$started=Start-CcodWorkerProcess -Kind Lifecycle -ScriptPath $helper -RequestPath ([IO.Path]::GetFullPath($configPath)) -ResultPath ([IO.Path]::GetFullPath($summaryPath)) -StderrPath $null -PowerShellPath $powershell
            $slot=[pscustomobject][ordered]@{ProcessId=$started.ProcessId;CreationTimeUtc=$started.CreationTimeUtc;Handle=$started.Handle;JobHandle=$started.JobHandle;RequestPath=$configPath;ResultPath=$summaryPath;StderrPath=$null}
            try{Assert-CcodTrue (Wait-CcodWorkerExit -Slot $slot -TimeoutMilliseconds 10000) "$Leaf child exits";if(-not[IO.File]::Exists($summaryPath)){$slot.Handle.Refresh();throw "delegated helper wrote no summary; exit=$($slot.Handle.ExitCode)"};$summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json;if($null-ne$summary.PSObject.Properties['error']){throw "delegated helper failed: $($summary.id) $($summary.error)"};return $summary}finally{Close-CcodWorkerHandle $slot}
        }
        $newOwnership=$null
        try{
            [void](Suspend-CcodLifecycleOwnership -Ownership $ownership -InstallRoot ([IO.Path]::GetFullPath($install)))
            $valid=Invoke-CcodDelegatedChild $ownership ([UInt64]$ownership.epoch) $false @('Inspect','Close','Apply') 'valid'
            Assert-CcodEqual 3 $valid.controllerCalls 'all three operations reach the real SessionController while account ownership is held'
            Assert-CcodEqual ',,' (@($valid.runs.controllerError)-join ',') 'real controller operations return no stable controller error'
            Assert-CcodEqual 'True,True,True' (@($valid.runs.controllerOk)-join ',') 'real controller operations return safe results under delegated ownership'
            Assert-CcodEqual ',,' (@($valid.runs.errorCode)-join ',') 'valid delegated operations return no stable error'
            Assert-CcodEqual '0,0,0' (@($valid.runs.exitCode)-join ',') 'Inspect Close and Apply avoid transition-busy deadlock'
            [void](Resume-CcodLifecycleOwnership -Ownership $ownership -InstallRoot ([IO.Path]::GetFullPath($install)) -UserSid $userSid -SessionId $sessionId)
            [void](Exit-CcodLifecycleOwnership $ownership)
            $newOwnership=Enter-CcodLifecycleOwnership -InstallRoot ([IO.Path]::GetFullPath($install)) -RuntimeId runtime-1 -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 5000
            [void](Suspend-CcodLifecycleOwnership -Ownership $newOwnership -InstallRoot ([IO.Path]::GetFullPath($install)))
            $stale=Invoke-CcodDelegatedChild $ownership ([UInt64]$ownership.epoch) $true @('Inspect') 'stale'
            Assert-CcodEqual 0 $stale.controllerCalls 'stale delegated epoch is rejected before the controller boundary'
            Assert-CcodEqual 1 $stale.runs[0].exitCode 'stale delegated operation fails closed'
            Assert-CcodEqual 'CCOD_LIFECYCLE_FENCE_STALE' $stale.runs[0].errorCode 'worker rejects the stale owner before its session lease'
            [void](Resume-CcodLifecycleOwnership -Ownership $newOwnership -InstallRoot ([IO.Path]::GetFullPath($install)) -UserSid $userSid -SessionId $sessionId)
            [void](Exit-CcodLifecycleOwnership $newOwnership)
        }finally{
            foreach($candidate in @($newOwnership,$ownership)){
                if($null-eq$candidate-or$candidate.released){continue}
                if($candidate.lease.Released){[void](Resume-CcodLifecycleOwnership -Ownership $candidate -InstallRoot ([IO.Path]::GetFullPath($install)) -UserSid $userSid -SessionId $sessionId)}
                [void](Exit-CcodLifecycleOwnership $candidate)
            }
        }
    }

    Invoke-CcodTest 'checkout and stale controller children fail runtime authorization before state or process IO' {
        $requestPath=[IO.Path]::GetFullPath((Join-Path $root 'process-request.json'));$processResultPath=[IO.Path]::GetFullPath((Join-Path $root 'process-result.json'));$stderrPath=[IO.Path]::GetFullPath((Join-Path $root 'process-stderr.txt'))
        $invalid=New-CcodControllerRequest;$invalid|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        [IO.Directory]::CreateDirectory((Split-Path $requestPath -Parent))|Out-Null
        [IO.File]::WriteAllText($requestPath,($invalid|ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
        $controllerPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\persistence\SessionController.ps1'))
        $fakeLocalAppData=[IO.Path]::GetFullPath((Join-Path $root 'checkout-localappdata'));$priorLocalAppData=$env:LOCALAPPDATA
        try{$env:LOCALAPPDATA=$fakeLocalAppData;$stdout=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controllerPath -RequestPath $requestPath -ResultPath $processResultPath 2>$stderrPath);$exitCode=$LASTEXITCODE}finally{$env:LOCALAPPDATA=$priorLocalAppData}
        $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $lines.Count 'process stdout contains exactly one nonblank JSON line'
        Assert-CcodEqual 1 $exitCode 'checkout controller process exits nonzero'
        $fromStdout=$lines[0]|ConvertFrom-Json;$fromFile=Get-Content -LiteralPath $processResultPath -Raw|ConvertFrom-Json
        Assert-CcodEqual ($fromFile|ConvertTo-Json -Depth 16 -Compress) ($fromStdout|ConvertTo-Json -Depth 16 -Compress) 'atomic result file and stdout carry the same object'
        Assert-CcodEqual 'CCOD_RUNTIME_UNAUTHORIZED' $fromStdout.error.code 'checkout controller cannot infer an installed root from PSScriptRoot'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $fakeLocalAppData 'CodexControlOtherDevices\state')) 'checkout rejection touches no state root'
        $stderrText=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath)}else{''}
        Assert-CcodTrue ($stderrText -cnotmatch 'schemaVersion') 'stderr does not contain a competing result object'

        $staleLocalAppData=[IO.Path]::GetFullPath((Join-Path $root 'stale-localappdata'));$installRoot=Join-Path $staleLocalAppData 'CodexControlOtherDevices';$staging=Join-Path $installRoot 'staging-active'
        [IO.Directory]::CreateDirectory($staging)|Out-Null;[IO.File]::WriteAllText((Join-Path $staging 'active.txt'),'active',[Text.UTF8Encoding]::new($false))
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion '2.0.0';$activeRuntime=Join-Path (Join-Path $installRoot 'runtime') $manifest.runtimeId
        [IO.Directory]::CreateDirectory((Split-Path $activeRuntime -Parent))|Out-Null;[IO.Directory]::Move($staging,$activeRuntime);[IO.File]::WriteAllText((Join-Path $activeRuntime 'manifest.json'),($manifest|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'),(([ordered]@{schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[UInt64]1;updatedAtUtc='2030-02-03T04:05:06.0000000Z'}|ConvertTo-Json -Depth 5)),[Text.UTF8Encoding]::new($false))
        $staleRuntime=Join-Path $installRoot 'runtime\stale-runtime';Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src') -Destination (Join-Path $staleRuntime 'src') -Recurse
        $staleController=[IO.Path]::GetFullPath((Join-Path $staleRuntime 'src\persistence\SessionController.ps1'));$staleResult=[IO.Path]::GetFullPath((Join-Path $root 'stale-result.json'))
        try{$env:LOCALAPPDATA=$staleLocalAppData;$staleStdout=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $staleController -RequestPath $requestPath -ResultPath $staleResult 2>$stderrPath);$staleExit=$LASTEXITCODE}finally{$env:LOCALAPPDATA=$priorLocalAppData}
        $staleLines=@($staleStdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $staleLines.Count 'stale runtime emits one framed error'
        Assert-CcodEqual 1 $staleExit 'stale runtime exits nonzero'
        Assert-CcodEqual 'CCOD_RUNTIME_UNAUTHORIZED' (($staleLines[0]|ConvertFrom-Json).error.code) 'non-active runtime controller is rejected before request dispatch'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $installRoot 'state')) 'stale runtime rejection touches no installed state'
    }
}catch{Write-Error $_;exit 1}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
