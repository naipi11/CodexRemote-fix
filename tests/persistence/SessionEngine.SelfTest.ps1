$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\SessionEngine.psm1') -Force

function New-CcodEngineSnapshot {
    param(
        [Alias('Pid')][int]$ProcessId = 100,
        [string]$CreationTimeUtc = '2030-02-03T04:00:00.0000000Z',
        [ValidateSet('Ordinary','Special','Unrelated')][string]$Mode = 'Ordinary',
        [AllowNull()][Nullable[int]]$ParentPid = $null,
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null,
        [bool]$IsTopLevel = $true
    )
    $commandLine='"C:\Codex\ChatGPT.exe"'
    if($Mode -ceq 'Special' -and $null -ne $RendererPort -and $null -ne $MainPort){
        $commandLine+=' --remote-debugging-address=127.0.0.1 --remote-debugging-port={0} --inspect=127.0.0.1:{1}' -f $RendererPort,$MainPort
    }
    [pscustomobject][ordered]@{
        Pid=$ProcessId; CreationTimeUtc=$CreationTimeUtc; SessionId=1; UserSid='S-1-5-21-test'
        Path='C:\Codex\ChatGPT.exe'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        CommandLine=$commandLine; ParentPid=$ParentPid; IsTopLevel=$IsTopLevel; Mode=$Mode
        RendererPort=$RendererPort; MainPort=$MainPort
    }
}

function New-CcodEngineRequest {
    param(
        [ValidateSet('Inspect','Close','Apply','RepairStale','RepairRenderer','Recover')][string]$Action = 'Inspect',
        [ValidateSet(1,2)][int]$SchemaVersion = 1,
        [string]$RuntimeId = 'runtime-1',
        [int]$SupervisorPid = 11,
        [string]$SupervisorCreationTimeUtc = '2030-02-03T03:00:00.0000000Z',
        $Source = $null,
        [bool]$ExistingOnly = $true,
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null,
        [bool]$RestartOrdinary = $true,
        [ValidateRange(1,120000)][int]$TimeoutMilliseconds = 30000,
        [string]$TransactionId = '5f496d99-c839-4458-a6a2-d37ea1afdbda'
    )
    $request=[ordered]@{
        schemaVersion=$SchemaVersion; action=$Action; transactionId=$TransactionId; runtimeId=$RuntimeId
    }
    if($SchemaVersion -eq 2){
        $request.runtimeGeneration=[UInt64]4
        $request.leaseEpoch=[UInt64]9
        $request.ownerIdentity=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
    }
    $request.supervisorIdentity=[pscustomobject][ordered]@{ pid=$SupervisorPid; creationTimeUtc=$SupervisorCreationTimeUtc; sessionId='1' }
    $request.source=$Source;$request.existingOnly=$ExistingOnly;$request.rendererPort=$RendererPort;$request.mainPort=$MainPort
    $request.timeoutMilliseconds=$TimeoutMilliseconds;$request.restartOrdinary=$RestartOrdinary
    [pscustomobject]$request
}

function New-CcodEnginePaths([string]$Root) {
    $stable = Join-Path $Root 'install'
    $state = Join-Path $stable 'state'
    $runtime = Join-Path $stable 'runtime\runtime-1'
    [pscustomobject][ordered]@{
        StateRoot=[IO.Path]::GetFullPath($state)
        TransitionPath=[IO.Path]::GetFullPath((Join-Path $state 'transition.json'))
        TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\transactions.log'))
        SessionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\session.log'))
        CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\check-package.mjs'))
        OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\orchestrator.js'))
        MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\main-payload.js'))
    }
}

function New-CcodEngineState {
    param(
        $Status = ([pscustomobject]@{ schemaVersion=1; session=$null }),
        $ActiveTransaction = $null,
        $VerifiedPackages = $null
    )
    if($null -eq $VerifiedPackages){
        $VerifiedPackages=if($null -ne $Status.session -and $null -ne $Status.session.codex){
            New-CcodEngineVerifiedPackages -RuntimeId $Status.session.runtimeId -PackageFullName $Status.session.codex.packageFullName -PackageVersion $Status.session.codex.packageVersion -AppAsarSha256 $Status.session.codex.appAsarSha256
        }else{[pscustomobject]@{ schemaVersion=1; packages=[pscustomobject]@{} }}
    }
    [pscustomobject]@{
        Settings=[pscustomobject]@{ automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:\Node\node.exe') }
        Status=$Status
        VerifiedPackages=$VerifiedPackages
        Transition=[pscustomobject]@{ schemaVersion=1; activeTransaction=$ActiveTransaction }
        AutomationEnabled=$true; AutomaticCandidateTrialsAllowed=$true; TransitionActionsAllowed=$true
        StatusRebuildRequired=$false; Damage=[pscustomobject]@{}
    }
}

function New-CcodEngineProbe {
    param([string]$Classification='CandidateCompatible')
    [pscustomobject]@{
        Ready=($Classification -ceq 'CandidateCompatible'); Code='CHECKER_OK'; StaticClassification=$Classification
        PackageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; PackageVersion='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe'
        AppAsarSha256=('a' * 64); NodePath='C:\Node\node.exe'; Signatures=[pscustomobject]@{}
        NativeModulePresent=($Classification -ceq 'NativeModulePresent')
    }
}

function New-CcodEngineActiveStatus {
    param(
        [string]$RuntimeId='runtime-1',
        [int]$SupervisorPid=11,
        [string]$SupervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z'
    )
    [pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=$SupervisorPid;supervisorCreationTimeUtc=$SupervisorCreationTimeUtc;sessionId='1';runtimeId=$RuntimeId;sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
}

function New-CcodEngineVerifiedPackages {
    param(
        [string]$RuntimeId='runtime-1',
        [string]$PackageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0',
        [string]$PackageVersion='1.0.0.0',
        [string]$AppAsarSha256=('a'*64),
        [string]$StaticClassification='CandidateCompatible',
        [string]$DynamicOutcome='Succeeded',
        [string]$ProbeState='Valid'
    )
    $key='{0}|{1}|{2}' -f $PackageFullName,$AppAsarSha256,$RuntimeId
    $packages=[ordered]@{}
    $packages[$key]=[ordered]@{
        packageFullName=$PackageFullName;packageVersion=$PackageVersion;appAsarSha256=$AppAsarSha256;runtimeId=$RuntimeId
        staticClassification=$StaticClassification;dynamicOutcome=$DynamicOutcome;probeState=$ProbeState;confirmedAtUtc='2030-02-03T04:06:00.0000000Z'
    }
    [pscustomobject][ordered]@{schemaVersion=1;packages=[pscustomobject]$packages}
}

function New-CcodInspectionState {
    param(
        $Status=(New-CcodEngineActiveStatus),
        $VerifiedPackages=(New-CcodEngineVerifiedPackages),
        [string[]]$NodeCandidates=@('C:\Node\node.exe')
    )
    [pscustomobject][ordered]@{
        Settings=[pscustomobject][ordered]@{schemaVersion=1;automationEnabled=$true;candidateCompatibleOptIn=$true;nodeCandidates=@($NodeCandidates);updatedAtUtc='2030-02-03T04:00:00.0000000Z'}
        Status=$Status
        VerifiedPackages=$VerifiedPackages
    }
}

function New-CcodPackageIdentity {
    [pscustomobject][ordered]@{
        Found=$true;Code='PACKAGE_FOUND';FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';FamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        Version='1.0.0.0';InstallLocation='C:\Codex';ExecutablePath='C:\Codex\ChatGPT.exe';AppAsarPath='C:\Codex\app.asar';NativeDirectory='C:\Codex\native'
    }
}

function New-CcodEngineTransition {
    param(
        [ValidateSet('IntentWritten','StopRequested','OrdinaryStopped','SpecialLaunchRequested','SpecialStarted','Validated','RecoveryLaunchRequested','Recovered','CloseRequested','Closed')][string]$Stage,
        [switch]$WithPorts,[switch]$WithSpecial,[switch]$WithRecovery,[switch]$Manual,
        [string]$TransactionId='3f91d267-44f2-4f23-855d-2b4577e7c118'
    )
    [pscustomobject][ordered]@{
        transactionId=$TransactionId;stage=$Stage;sourcePid=if($Manual){$null}else{100};sourceCreationTimeUtc=if($Manual){$null}else{'2030-02-03T04:00:00.0000000Z'}
        packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';appAsarSha256=('a'*64);runtimeId='runtime-1'
        mainPort=if($WithPorts){41002}else{$null};rendererPort=if($WithPorts){41001}else{$null}
        specialPid=if($WithSpecial){201}else{$null};specialCreationTimeUtc=if($WithSpecial){'2030-02-03T04:05:07.0000000Z'}else{$null}
        recoveryPid=if($WithRecovery){301}else{$null};recoveryCreationTimeUtc=if($WithRecovery){'2030-02-03T04:06:01.0000000Z'}else{$null}
        createdAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:06:02.0000000Z'
    }
}

function New-CcodFullBridgeInvocation {
    $proof = [ordered]@{
        ok=$true; protocolVersion=1
        main=[ordered]@{ inspectorPortClosed=[ordered]@{ confirmed=$true; code='ECONNREFUSED' }; payloadReport=[ordered]@{ installed=$true } }
        renderer=[ordered]@{
            targetUrl='app://-/index.html'; currentDocument=[ordered]@{ installed=$true }
            newDocumentScriptInstalled=$true; probe=[ordered]@{ proof=$true; targetGate='782640499' }
        }
    }
    [pscustomobject][ordered]@{ ExitCode=0; Stdout=($proof | ConvertTo-Json -Depth 16 -Compress); Stderr='' }
}

function New-CcodRendererBridgeInvocation {
    $proof=[ordered]@{ok=$true;protocolVersion=1;renderer=[ordered]@{targetUrl='app://-/index.html';currentDocument=[ordered]@{installed=$true};newDocumentScriptInstalled=$true;probe=[ordered]@{proof=$true;targetGate='782640499'}}}
    [pscustomobject][ordered]@{ExitCode=0;Stdout=($proof|ConvertTo-Json -Depth 16 -Compress);Stderr=''}
}

function New-CcodProbeBridgeInvocation {
    param(
        [ValidateSet('ECONNREFUSED','OPEN','TIMEOUT')][string]$MainCode='ECONNREFUSED',
        [AllowNull()]$TargetUrl='app://-/index.html',
        [bool]$Proof=$true,
        [AllowNull()]$TargetGate='782640499'
    )
    $frame=[ordered]@{
        ok=$true;protocolVersion=1
        main=[ordered]@{inspectorPortClosed=[ordered]@{confirmed=($MainCode -ceq 'ECONNREFUSED');code=$MainCode}}
        renderer=[ordered]@{targetUrl=$TargetUrl;probe=[ordered]@{proof=$Proof;targetGate=$TargetGate}}
    }
    [pscustomobject][ordered]@{ExitCode=0;Stdout=($frame|ConvertTo-Json -Depth 16 -Compress);Stderr=''}
}

function New-CcodInspectionAdapters {
    param(
        $InspectionState=(New-CcodInspectionState),
        $PackageIdentity=(New-CcodPackageIdentity),
        [object[]]$PreProcesses=@(),
        [object[]]$PostProcesses=$null,
        $BridgeInvocation=(New-CcodProbeBridgeInvocation),
        $Counters=$null
    )
    $stateValue=$InspectionState;$packageValue=$PackageIdentity;$preValues=@($PreProcesses)
    $postValues=if($null -eq $PostProcesses){@($PreProcesses)}else{@($PostProcesses)}
    $counts=if($null -eq $Counters){[pscustomobject]@{Read=0;Package=0;Node=0;Invoke=0;List=0;Match=0;Persisted=0}}else{$Counters}
    $listCall=[pscustomobject]@{Value=0}
    @{
        ReadInspectionState={param($StateRoot)$counts.Read++;$stateValue}.GetNewClosure()
        GetPackageIdentity={param($Ignored)$counts.Package++;$packageValue}.GetNewClosure()
        ResolveNodeCandidate={param($NodeCandidates)$counts.Node++;[pscustomobject][ordered]@{Found=$true;Code='NODE_SUPPORTED';Path='C:\Node\node.exe';Version='v22.0.0';Major=22;Capabilities=[pscustomobject]@{Supported=$true;Version='v22.0.0';Major=22}}}.GetNewClosure()
        GetPersistedSpecialIdentity={param($Status)$counts.Persisted++;$Status.session.codex}.GetNewClosure()
        InvokeNode={param($NodePath,$Arguments)$counts.Invoke++;$BridgeInvocation}.GetNewClosure()
        CurrentIdentity={[pscustomobject][ordered]@{SessionId='1';UserSid='S-1-5-21-test'}}
        ListProcesses={param($StatusEvidence)$counts.List++;$listCall.Value++;if($listCall.Value -eq 1){@($preValues)}else{@($postValues)}}.GetNewClosure()
        ProcessMatch={param($Expected,$Actual)$counts.Match++;$null -ne $Actual -and $Expected.Pid -eq $Actual.Pid -and $Expected.CreationTimeUtc -ceq $Actual.CreationTimeUtc}.GetNewClosure()
    }
}

function Invoke-CcodParserOnlyBridgeChild {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $driver=@'
const orchestrator = require(process.argv[1]);
try {
  const options = orchestrator.parseArguments(process.argv.slice(2));
  const renderer = {targetUrl:'app://-/index.html',currentDocument:{installed:true},newDocumentScriptInstalled:true,probe:{proof:true,targetGate:'782640499'}};
  const proof = options.mode === 'full'
    ? {ok:true,protocolVersion:1,main:{inspectorPortClosed:{confirmed:true,code:'ECONNREFUSED'},payloadReport:{installed:true}},renderer}
    : {ok:true,protocolVersion:1,renderer};
  process.stdout.write(JSON.stringify(proof));
} catch (error) {
  process.stdout.write(JSON.stringify({ok:false,error:{code:error.code || 'UNEXPECTED_ERROR'}}));
  process.exitCode = 1;
}
'@
    $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-parser-$([guid]::NewGuid().ToString('N')).err")))
    try{
        $node=(Get-Command node.exe -ErrorAction Stop).Source
        $parserPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\runtime\orchestrator.js'))
        $cliArguments=@($Arguments|Select-Object -Skip 1)
        $stdout=@(& $node -e $driver $parserPath @cliArguments 2>$stderrPath)
        $exitCode=$LASTEXITCODE
        $stderr=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath)}else{''}
    }finally{if([IO.File]::Exists($stderrPath)){[IO.File]::Delete($stderrPath)}}
    [pscustomobject][ordered]@{ExitCode=$exitCode;Stdout=($stdout -join "`n");Stderr=$stderr}
}

function New-CcodEngineAdapters {
    param(
        $State=(New-CcodEngineState),
        $Probe=(New-CcodEngineProbe),
        [object[]]$Processes=@(),
        [string]$StopOutcome='Stopped',
        $Events=$null,
        $Counters=$null
    )
    $stateValue=$State; $probeValue=$Probe; $processValues=@($Processes); $stopValue=$StopOutcome
    $eventsValue=$Events
    if($null -eq $eventsValue){$eventsValue=[Collections.Generic.List[string]]::new()}
    $counts=if($null -eq $Counters){[pscustomobject]@{ SpecialStart=0; OrdinaryStart=0; Recover=0; Node=0 }}else{$Counters}
    $active=[pscustomobject]@{ Stage='IntentWritten' }
    $snapshotFactory=${function:New-CcodEngineSnapshot}
    $fullBridgeFactory=${function:New-CcodFullBridgeInvocation}
    $rendererBridgeFactory=${function:New-CcodRendererBridgeInvocation}
    return @{
        ReadState={ param($StateRoot,$SuppressionKey) $stateValue }.GetNewClosure()
        GetPackageIdentity={New-CcodPackageIdentity}
        StaticProbe={ param($NodeCandidates,$CheckerPath) $eventsValue.Add('StaticProbe'); $probeValue }.GetNewClosure()
        ListProcesses={ param($StatusEvidence) @($processValues) }.GetNewClosure()
        GetProcess={ param($Pid,$StatusEvidence) @($processValues | Where-Object { $_.Pid -eq $Pid } | Select-Object -First 1) }.GetNewClosure()
        ObserveProcessIdentity={ param($ProcessId,$ExpectedCreationTimeUtc) [pscustomobject][ordered]@{Outcome='SameIdentity';Pid=[int]$ProcessId;CreationTimeUtc=[string]$ExpectedCreationTimeUtc} }
        ProcessMatch={ param($Expected,$Actual) $null -ne $Actual -and $Expected.Pid -eq $Actual.Pid -and $Expected.CreationTimeUtc -ceq $Actual.CreationTimeUtc -and $Expected.Mode -ceq $Actual.Mode }
        NewTransition={
            param($Path,$Source,$Package,$RuntimeId,$RendererPort,$MainPort,$TransactionId)
            $eventsValue.Add('IntentWritten'); $active.Stage='IntentWritten'
            [pscustomobject]@{ transactionId=$TransactionId; stage='IntentWritten'; sourcePid=if($Source){$Source.Pid}else{$null}; sourceCreationTimeUtc=if($Source){$Source.CreationTimeUtc}else{$null}; packageFullName=$Package.FullName; appAsarSha256=$Package.AppAsarSha256; runtimeId=$RuntimeId; mainPort=$MainPort; rendererPort=$RendererPort; specialPid=$null; specialCreationTimeUtc=$null; recoveryPid=$null; recoveryCreationTimeUtc=$null; createdAtUtc='2030-02-03T04:05:06.0000000Z'; updatedAtUtc='2030-02-03T04:05:06.0000000Z' }
        }.GetNewClosure()
        SetTransition={
            param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)
            $eventsValue.Add($NewStage); $active.Stage=$NewStage
            [pscustomobject]@{ transactionId=$TransactionId; stage=$NewStage; mainPort=$MainPort; rendererPort=$RendererPort; specialPid=if($SpecialIdentity){$SpecialIdentity.Pid}else{$null}; specialCreationTimeUtc=if($SpecialIdentity){$SpecialIdentity.CreationTimeUtc}else{$null}; recoveryPid=if($RecoveryIdentity){$RecoveryIdentity.Pid}else{$null}; recoveryCreationTimeUtc=if($RecoveryIdentity){$RecoveryIdentity.CreationTimeUtc}else{$null} }
        }.GetNewClosure()
        CompleteTransition={ param($Path,$LogPath,$TransactionId,$Disposition) $eventsValue.Add("Complete:$Disposition"); [pscustomobject]@{ Outcome='Completed' } }.GetNewClosure()
        StopProcess={
            param($Expected,$StatusEvidence,$TimeoutMilliseconds)
            $eventsValue.Add('StopProcess')
            [pscustomobject]@{ Outcome=$stopValue; StoppedByController=($stopValue -ceq 'Stopped'); Snapshot=if($stopValue -ceq 'SourceExited'){$null}else{$Expected} }
        }.GetNewClosure()
        FindStalePackageRoot={param($Package,$StatusEvidence)[pscustomobject][ordered]@{Outcome='NoCandidate';Snapshot=$null}}
        GetStaleTree={param($Root,$Package)@()}
        GetStaleProcess={param($ProcessId,$Package)$null}
        StopStaleProcess={param($Expected,$Package,$TimeoutMilliseconds)[pscustomobject]@{Outcome='SourceExited';StoppedByController=$false;Snapshot=$null}}
        RequestStaleGracefulClose={param($Expected,$Package)[pscustomobject]@{Outcome='SourceExited';Snapshot=$null}}
        WaitStaleProcessExit={param($Expected,$Package,$TimeoutMilliseconds)[pscustomobject]@{Outcome='SourceExited';Snapshot=$null}}
        GetPreferredRendererPort={ param($Excluded) 9335 }
        GetPort={ param($Excluded) if(@($Excluded) -contains 9335 -or @($Excluded) -contains 41001){41002}else{41001} }
        StartSpecial={
            param($RendererPort,$MainPort,$TimeoutMilliseconds)
            $eventsValue.Add('StartSpecial'); $counts.SpecialStart++
            [pscustomobject]@{ Outcome='Started'; Snapshot=(& $snapshotFactory -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort $RendererPort -MainPort $MainPort); Process=[pscustomobject]@{Id=201} }
        }.GetNewClosure()
        InvokeNode={ param($NodePath,$Arguments) $eventsValue.Add('InvokeNode'); $counts.Node++; if((@($Arguments)-join ',') -cmatch '--mode,renderer(?:,|$)'){& $rendererBridgeFactory}else{& $fullBridgeFactory} }.GetNewClosure()
        WriteStatus={ param($StateRoot,$Status,$LiveProbe) $eventsValue.Add('WriteStatus') }.GetNewClosure()
        ReadVerified={ param($StateRoot) [pscustomobject]@{ schemaVersion=1; packages=[pscustomobject]@{} } }
        WriteVerified={ param($StateRoot,$Verified) $eventsValue.Add('WriteVerified') }.GetNewClosure()
        UtcNow={ [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime() }
        GetTree={ param($Root,$StatusEvidence) @($Root) }
        WaitPortClosed={ param($Port,$TimeoutMilliseconds) $true }
        StartOrdinary={ param($TimeoutMilliseconds) $counts.OrdinaryStart++; [pscustomobject]@{ Outcome='Adopted'; Snapshot=(& $snapshotFactory -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'); Process=$null } }.GetNewClosure()
        Delay={ param($Milliseconds) }
        CurrentIdentity={ [pscustomobject][ordered]@{SessionId='1';UserSid='S-1-5-21-test'} }
        GetSupervisorProcess={ param($ProcessId) [pscustomobject][ordered]@{Pid=[int]$ProcessId;CreationTimeUtc='2030-02-03T03:00:00.0000000Z';SessionId='1'} }
        AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity)$true}
        Events=$eventsValue
        Counters=$counts
    }
}

function Set-CcodEngineAliveIdentityObserver {
    param([Parameter(Mandatory)][hashtable]$Adapters,[Parameter(Mandatory)][hashtable]$Alive)
    $aliveMap=$Alive
    $Adapters.ObserveProcessIdentity={
        param($ProcessId,$ExpectedCreationTimeUtc)
        if(-not $aliveMap.ContainsKey([int]$ProcessId)){return [pscustomobject][ordered]@{Outcome='Absent';Pid=[int]$ProcessId;CreationTimeUtc=$null}}
        $creation=[string]$aliveMap[[int]$ProcessId].CreationTimeUtc
        [pscustomobject][ordered]@{Outcome=if($creation -ceq $ExpectedCreationTimeUtc){'SameIdentity'}else{'IdentityChanged'};Pid=[int]$ProcessId;CreationTimeUtc=$creation}
    }.GetNewClosure()
}

function Assert-CcodEngineResultContract($Result,[string]$TransactionId,[string]$Message) {
    Assert-CcodEqual 'schemaVersion,action,ok,outcome,safeState,stage,transactionId,package,source,special,probes,recovery,error,logFile' (($Result.PSObject.Properties.Name) -join ',') "$Message exact 14 fields"
    Assert-CcodEqual $TransactionId $Result.transactionId "$Message request correlation"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-engine-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    $paths = New-CcodEnginePaths -Root $root

    Invoke-CcodTest 'exports the fenced Close boundary with the existing session operations' {
        Assert-CcodEqual 'Invoke-CcodApplySession,Invoke-CcodCloseSession,Invoke-CcodInspectSession,Invoke-CcodRecoverSession,Invoke-CcodRepairRenderer,Invoke-CcodRepairStaleSession,Invoke-CcodReplayTransition,Test-CcodBridgeResult' `
            ((Get-Command -Module SessionEngine | Sort-Object Name | ForEach-Object Name) -join ',') 'public API remains exact'
    }

    Invoke-CcodTest 'strictly validates full and renderer bridge framing and proof' {
        $full = Test-CcodBridgeResult -Mode Full -Invocation (New-CcodFullBridgeInvocation)
        Assert-CcodEqual $true $full.ok 'full proof passes'
        $rendererProof = [ordered]@{ ok=$true; protocolVersion=1; renderer=[ordered]@{ targetUrl='app://-/index.html'; currentDocument=[ordered]@{installed=$true}; newDocumentScriptInstalled=$true; probe=[ordered]@{proof=$true;targetGate='782640499'} } }
        $renderer = Test-CcodBridgeResult -Mode Renderer -Invocation ([pscustomobject][ordered]@{ ExitCode=0; Stdout=($rendererProof|ConvertTo-Json -Depth 16 -Compress); Stderr='diagnostic' })
        Assert-CcodEqual $false ($null -ne $renderer.PSObject.Properties['main']) 'renderer proof forbids a main result'
        Assert-CcodThrows { Test-CcodBridgeResult -Mode Full -Invocation ([pscustomobject][ordered]@{ExitCode=0;Stdout='{} {}';Stderr=''}) } 'CCOD_BRIDGE_JSON_INVALID'
        foreach($invocation in @(
            [pscustomobject][ordered]@{ExitCode=0;Stdout='{"ok":true,"protocolVersion":1}';Stderr=''},
            [pscustomobject][ordered]@{ExitCode=1;Stdout='{}';Stderr='failed'}
        )) { Assert-CcodThrows { Test-CcodBridgeResult -Mode Full -Invocation $invocation } 'BRIDGE_PROOF_INCOMPLETE' }
        $wrongCode=New-CcodFullBridgeInvocation;$wrongObject=$wrongCode.Stdout|ConvertFrom-Json;$wrongObject.main.inspectorPortClosed.code='EOTHER';$wrongCode.Stdout=$wrongObject|ConvertTo-Json -Depth 16 -Compress
        Assert-CcodThrows {Test-CcodBridgeResult -Mode Full -Invocation $wrongCode} 'BRIDGE_PROOF_INCOMPLETE'
    }

    Invoke-CcodTest 'strictly validates every completed Probe frame and rejects malformed evidence' {
        $rendererCases=@(
            [pscustomobject]@{TargetUrl='app://-/index.html';Proof=$true;TargetGate='782640499'},
            [pscustomobject]@{TargetUrl=$null;Proof=$false;TargetGate=$null},
            [pscustomobject]@{TargetUrl='app://-/index.html';Proof=$false;TargetGate=$null},
            [pscustomobject]@{TargetUrl='app://-/index.html';Proof=$false;TargetGate='782640499'}
        )
        foreach($mainCode in @('ECONNREFUSED','OPEN','TIMEOUT')){
            foreach($rendererCase in $rendererCases){
                $parsed=Test-CcodBridgeResult -Mode Probe -Invocation (New-CcodProbeBridgeInvocation -MainCode $mainCode -TargetUrl $rendererCase.TargetUrl -Proof $rendererCase.Proof -TargetGate $rendererCase.TargetGate)
                Assert-CcodEqual $mainCode $parsed.main.inspectorPortClosed.code "$mainCode legal Probe frame passes"
                Assert-CcodEqual $rendererCase.Proof $parsed.renderer.probe.proof 'legal renderer proof Boolean is preserved'
            }
        }

        $valid=(New-CcodProbeBridgeInvocation).Stdout|ConvertFrom-Json
        $malformed=[Collections.Generic.List[object]]::new()
        foreach($mutator in @(
            {param($x)$x|Add-Member extra $true},
            {param($x)$x.PSObject.Properties.Remove('main')},
            {param($x)$x.ok='true'},
            {param($x)$x.protocolVersion='1'},
            {param($x)$x.main|Add-Member extra $true},
            {param($x)$x.main.inspectorPortClosed.confirmed=$false},
            {param($x)$x.main.inspectorPortClosed.code='econnrefused'},
            {param($x)$x.main.inspectorPortClosed.confirmed=$true;$x.main.inspectorPortClosed.code='OPEN'},
            {param($x)$x.renderer|Add-Member extra $true},
            {param($x)$x.renderer.targetUrl='APP://-/index.html'},
            {param($x)$x.renderer.probe.proof='true'},
            {param($x)$x.renderer.probe.targetGate='different'},
            {param($x)$x.renderer.probe.proof=$true;$x.renderer.probe.targetGate=$null},
            {param($x)$x.renderer.targetUrl=$null;$x.renderer.probe.proof=$true},
            {param($x)$x.renderer.targetUrl=$null;$x.renderer.probe.proof=$false;$x.renderer.probe.targetGate='782640499'},
            {param($x)$x.renderer.probe|Add-Member extra $true}
        )){
            $copy=($valid|ConvertTo-Json -Depth 16 -Compress)|ConvertFrom-Json
            & $mutator $copy
            $malformed.Add([pscustomobject][ordered]@{ExitCode=0;Stdout=($copy|ConvertTo-Json -Depth 16 -Compress);Stderr=''})
        }
        $malformed.Add([pscustomobject][ordered]@{ExitCode=0;Stdout='[]';Stderr=''})
        $malformed.Add([pscustomobject][ordered]@{ExitCode=0;Stdout='null';Stderr=''})
        foreach($invocation in $malformed){Assert-CcodThrows {Test-CcodBridgeResult -Mode Probe -Invocation $invocation} 'CCOD_BRIDGE_JSON_INVALID'}
        Assert-CcodThrows {Test-CcodBridgeResult -Mode Probe -Invocation ([pscustomobject][ordered]@{ExitCode=1;Stdout='{}';Stderr='safe'})} 'BRIDGE_PROOF_INCOMPLETE'
        Assert-CcodThrows {Test-CcodBridgeResult -Mode Probe -Invocation ([pscustomobject][ordered]@{ExitCode=0;Stdout='';Stderr=''})} 'BRIDGE_PROOF_INCOMPLETE'
    }

    Invoke-CcodTest 'returns exact correlated results and rejects request or path coercion before adapters' {
        $request = New-CcodEngineRequest
        $before = $request | ConvertTo-Json -Depth 16 -Compress
        $emptyInspection=New-CcodInspectionState -Status ([pscustomobject]@{schemaVersion=1;session=$null}) -VerifiedPackages ([pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{}})
        $result = Invoke-CcodInspectSession -Request $request -Paths $paths -Adapters (New-CcodInspectionAdapters -InspectionState $emptyInspection)
        Assert-CcodEngineResultContract $result $request.transactionId 'valid inspect'
        Assert-CcodEqual 'Inspected' $result.outcome 'valid no-process inspect is safe'
        Assert-CcodEqual 'NoCodex' $result.safeState 'no process remains a read-only fact'
        Assert-CcodEqual $before ($request | ConvertTo-Json -Depth 16 -Compress) 'request input is not mutated'

        $extra = New-CcodEngineRequest
        $extra | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        $invalid = Invoke-CcodInspectSession -Request $extra -Paths $paths -Adapters @{ ReadState={throw 'must not run'} }
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $invalid.error.code 'extra request field fails closed'
        Assert-CcodEngineResultContract $invalid $extra.transactionId 'invalid request'

        $poisoned=New-CcodEngineRequest;$poisoned.transactionId="C:\secret\device-key.json`n--token hunter2"
        $poisonedResult=Invoke-CcodInspectSession -Request $poisoned -Paths $paths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual $null $poisonedResult.transactionId 'a noncanonical transaction ID is never echoed from an invalid request'
        Assert-CcodTrue (($poisonedResult|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'secret|hunter2|device-key') 'invalid request metadata cannot bypass the fixed public error envelope'

        $badPaths = New-CcodEnginePaths -Root $root
        $badPaths.CheckerPath = 'relative\check-package.mjs'
        $pathFailure = Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $badPaths -Adapters @{ ReadState={throw 'must not run'} }
        Assert-CcodEqual 'CCOD_PATHS_INVALID' $pathFailure.error.code 'relative path fails before state or process adapters'

        $outsidePaths=New-CcodEnginePaths -Root $root;$outsidePaths.OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $root 'outside\orchestrator.js'))
        $outsideFailure=Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $outsidePaths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual 'CCOD_PATHS_INVALID' $outsideFailure.error.code 'runtime payload outside the shared verified runtime root fails before adapters'

        $specialSource=New-CcodEngineSnapshot -Mode Special -RendererPort 41001 -MainPort 41002
        $sourceFailure=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $specialSource) -Paths $paths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $sourceFailure.error.code 'Apply source must be an exact top-level ordinary snapshot'
        $samePorts=New-CcodEngineRequest -Action Apply -Source (New-CcodEngineSnapshot) -RendererPort 41001 -MainPort 41001
        $portFailure=Invoke-CcodApplySession -Request $samePorts -Paths $paths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $portFailure.error.code 'equal requested ports fail before source or journal adapters'
    }

    Invoke-CcodTest 'Inspect writes no diagnostics while mutating actions keep bounded allowlisted diagnostics' {
        $secret="C:\secret\device-key.json`n--token hunter2`ncommand.exe --password=swordfish"
        $inspectWrites=[pscustomobject]@{Count=0}
        $inspectResult=Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters @{
            ReadInspectionState={throw $secret}.GetNewClosure()
            WriteLog={param($Path,$Message)$inspectWrites.Count++}.GetNewClosure()
            ReadState={throw 'aggregate reader must not run'}
        }
        Assert-CcodEqual 'CCOD_SESSION_FAILED' $inspectResult.error.code 'unknown Inspect adapter errors use the stable session code'
        Assert-CcodEqual 0 $inspectWrites.Count 'Inspect errors never write diagnostics'
        Assert-CcodEqual $null $inspectResult.logFile 'Inspect errors publish no log path'

        $messages=[Collections.Generic.List[string]]::new()
        $source=New-CcodEngineSnapshot
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters @{
            ReadState={throw $secret}.GetNewClosure()
            WriteLog={param($Path,$Message)$messages.Add($Message);'incidental adapter output'}.GetNewClosure()
        }
        Assert-CcodTrue ($result -is [pscustomobject]) 'diagnostic adapter output never corrupts the one-result engine frame'
        Assert-CcodEqual 'CCOD_SESSION_FAILED' $result.error.code 'unknown adapter errors use the stable session code'
        Assert-CcodEqual 'The session operation failed safely. See the session log for details.' $result.error.message 'public error text is fixed and generic'
        Assert-CcodTrue ($result.error.message.Length -le 300) 'public error text remains bounded'
        Assert-CcodEqual $paths.SessionLogPath $result.logFile 'successful diagnostic persistence returns only the safe log reference'
        Assert-CcodEqual 1 $messages.Count 'one core failure writes one diagnostic record'
        Assert-CcodTrue ($messages[0] -cnotmatch 'secret|hunter2|swordfish|command\.exe|[\r\n]') 'diagnostic record excludes raw path command secret and multiline text'
        $record=$messages[0]|ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code,reason' (($record.PSObject.Properties.Name)-join ',') 'diagnostic log uses the fixed allowlist'
        Assert-CcodEqual 'Unclassified' $record.reason 'unknown adapter failure records only the allow-listed fallback reason'

        [IO.Directory]::CreateDirectory((Split-Path $paths.SessionLogPath -Parent))|Out-Null
        [IO.File]::WriteAllText($paths.SessionLogPath,('x'*(2MB+1)),[Text.UTF8Encoding]::new($false))
        $default=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TransactionId '9c2324b9-07a4-4ad3-9de5-c48dde73c713') -Paths $paths -Adapters @{ReadState={throw $secret}.GetNewClosure()}
        Assert-CcodEqual $paths.SessionLogPath $default.logFile 'default adapter writes the same safe session log reference'
        Assert-CcodTrue ((Get-Item -LiteralPath $paths.SessionLogPath).Length -lt 2MB) 'default rotating log replaces an unsafe oversized current file'
        $lines=@(Get-Content -LiteralPath $paths.SessionLogPath|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $lines.Count 'default failure log contains one bounded JSONL record'
        Assert-CcodTrue ($lines[0] -cnotmatch 'secret|hunter2|swordfish|command\.exe') 'default rotating log is redacted by construction'
        Assert-CcodEqual $false (Test-Path -LiteralPath ($paths.SessionLogPath+'.11')) 'rotation never creates an eleventh history generation'
    }

    Invoke-CcodTest 'records only exact safe close failure reasons without exception text' {
        $cases=@(
            [pscustomobject]@{Message='Recorded Active root is missing, changed, or accompanied by another root';Reason='RecordedActiveMismatch'},
            [pscustomobject]@{Message='Recorded Active root cannot be safely replaced';Reason='RecordedActiveMismatch'},
            [pscustomobject]@{Message='Multiple current-package close roots are ambiguous';Reason='MultipleRoots'},
            [pscustomobject]@{Message='A status-less debug root lacks one valid distinct port pair';Reason='MissingPortPair'},
            [pscustomobject]@{Message='A replacement debug root lacks one valid distinct port pair';Reason='MissingPortPair'},
            [pscustomobject]@{Message='Requested close source is not the one verified current root';Reason='RequestedSourceMismatch'},
            [pscustomobject]@{Message='Current close target tree is not exact and verified';Reason='EmptyVerifiedTree'},
            [pscustomobject]@{Message="unknown C:\\private\\target`n--token hunter2";Reason='Unclassified'}
        )
        foreach($case in $cases){
            $messages=[Collections.Generic.List[string]]::new()
            $record=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($case.Message),'CCOD_CLOSE_UNPROVEN',[Management.Automation.ErrorCategory]::InvalidData,$null)
            $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source (New-CcodEngineSnapshot) -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters @{
                ReadState={throw $record}.GetNewClosure()
                WriteLog={param($Path,$Message)$messages.Add($Message)}.GetNewClosure()
            }
            Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $result.error.code "$($case.Reason) retains the stable failure code"
            Assert-CcodEqual 1 $messages.Count "$($case.Reason) writes one diagnostic record"
            $diagnostic=$messages[0]|ConvertFrom-Json
            Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code,reason' (($diagnostic.PSObject.Properties.Name)-join ',') "$($case.Reason) uses only the diagnostic allowlist"
            Assert-CcodEqual 2 $diagnostic.schemaVersion "$($case.Reason) uses diagnostic schema 2"
            Assert-CcodEqual $case.Reason $diagnostic.reason "$($case.Reason) maps only the exact stable predicate"
            Assert-CcodTrue ($messages[0] -cnotmatch 'private|target|hunter2|[\r\n]') "$($case.Reason) never logs raw exception text"
        }
    }

    Invoke-CcodTest 'maps every unrecognized prefixed error ID to the stable generic code' {
        foreach($case in @(
            [pscustomobject]@{Name='token';Id='CCOD_LEAK_PRIVATE_TOKEN';Marker='LEAK_PRIVATE_TOKEN'},
            [pscustomobject]@{Name='path';Id='BRIDGE_C:\private\device-key.json';Marker='device-key'},
            [pscustomobject]@{Name='newline';Id="CCOD_LEAK`n--token hunter2";Marker='hunter2'},
            [pscustomobject]@{Name='comma';Id='CCOD_LEAK_COMMA,command-secret';Marker='LEAK_COMMA'},
            [pscustomobject]@{Name='long';Id=('CCOD_'+('X'*2048)+'_PRIVATE_TOKEN');Marker=('X'*128)}
        )){
            $messages=[Collections.Generic.List[string]]::new()
            $errorRecord=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('safe internal failure'),$case.Id,[Management.Automation.ErrorCategory]::InvalidData,$null)
            $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source (New-CcodEngineSnapshot) -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters @{
                ReadState={throw $errorRecord}.GetNewClosure()
                WriteLog={param($Path,$Message)$messages.Add($Message)}.GetNewClosure()
            }
            Assert-CcodEqual 'CCOD_SESSION_FAILED' $result.error.code "$($case.Name) prefixed ID maps to the stable generic code"
            Assert-CcodEqual 1 $messages.Count "$($case.Name) prefixed failure writes one diagnostic"
            $published=($result|ConvertTo-Json -Depth 16 -Compress)+$messages[0]
            Assert-CcodTrue ($published -cnotmatch [regex]::Escape($case.Marker)) "$($case.Name) prefixed ID is absent from result and log"
            Assert-CcodTrue ($published -cnotmatch 'private|hunter2|command-secret') "$($case.Name) prefixed ID exposes no path token or comma suffix"
        }
    }

    Invoke-CcodTest 'probes one exact persisted special read-only with current or older exact provenance' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        foreach($statusRuntime in @('runtime-1','runtime-old')){
            $status=New-CcodEngineActiveStatus -RuntimeId $statusRuntime
            $state=New-CcodInspectionState -Status $status -VerifiedPackages (New-CcodEngineVerifiedPackages -RuntimeId $statusRuntime)
            $counts=[pscustomobject]@{Read=0;Package=0;Node=0;Invoke=0;List=0;Match=0;Persisted=0;Forbidden=0}
            $capture=[pscustomobject]@{Node=$null;Arguments=$null}
            $adapters=New-CcodInspectionAdapters -InspectionState $state -PreProcesses @($special) -Counters $counts
            $adapters.InvokeNode={param($NodePath,$Arguments)$counts.Invoke++;$capture.Node=$NodePath;$capture.Arguments=@($Arguments);New-CcodProbeBridgeInvocation}.GetNewClosure()
            foreach($name in @('ReadState','StaticProbe','WriteLog','WriteStatus','WriteVerified','NewTransition','SetTransition','CompleteTransition','StopProcess','StartSpecial','WaitPortClosed')){$adapters[$name]={$counts.Forbidden++;throw 'forbidden Inspect mutation'}.GetNewClosure()}
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters $adapters
            Assert-CcodEngineResultContract $result '5f496d99-c839-4458-a6a2-d37ea1afdbda' "$statusRuntime Inspect"
            Assert-CcodEqual 'Inspected' $result.outcome "$statusRuntime session is observed"
            Assert-CcodEqual 'SpecialValidated' $result.safeState "$statusRuntime exact positive proof validates special"
            Assert-CcodEqual 'Inspected' $result.stage "$statusRuntime Inspect reaches terminal stage"
            Assert-CcodEqual 201 $result.special.pid "$statusRuntime exact special is returned"
            Assert-CcodEqual $null $result.probes "$statusRuntime periodic probe is never published in controller results"
            Assert-CcodEqual 'C:\Node\node.exe' $capture.Node "$statusRuntime Node comes from configured candidates"
            Assert-CcodEqual "$($paths.OrchestratorPath),--mode,probe,--renderer-port,41001,--main-port,41002,--timeout-ms,30000" ($capture.Arguments -join ',') "$statusRuntime executes only the current runtime probe path"
            Assert-CcodEqual 1 $counts.Read "$statusRuntime state is composed once before probe"
            Assert-CcodEqual 2 $counts.List "$statusRuntime enumerates before and after probe"
            Assert-CcodEqual 0 $counts.Forbidden "$statusRuntime Inspect performs no aggregate read or mutation"
        }

        $restartStatus=New-CcodEngineActiveStatus -RuntimeId 'runtime-old' -SupervisorPid 11 -SupervisorCreationTimeUtc '2030-02-03T03:00:00.0000000Z'
        $restartState=New-CcodInspectionState -Status $restartStatus -VerifiedPackages (New-CcodEngineVerifiedPackages -RuntimeId 'runtime-old')
        $restartRequest=New-CcodEngineRequest -SupervisorPid 22 -SupervisorCreationTimeUtc '2030-02-03T05:00:00.0000000Z' -TransactionId '79258e6a-b928-4322-b865-e79d4cbcbf33'
        $afterRestart=Invoke-CcodInspectSession -Request $restartRequest -Paths $paths -Adapters (New-CcodInspectionAdapters -InspectionState $restartState -PreProcesses @($special))
        Assert-CcodEqual 'Inspected' $afterRestart.outcome 'new supervisor can inspect historical special status'
        Assert-CcodEqual 'SpecialValidated' $afterRestart.safeState 'historical supervisor PID and creation do not replace current SID and Session authority'
        Assert-CcodEqual $null $afterRestart.probes 'post-restart Inspect keeps probes null'

        foreach($negative in @(
            (New-CcodProbeBridgeInvocation -TargetUrl $null -Proof $false -TargetGate $null),
            (New-CcodProbeBridgeInvocation -Proof $false -TargetGate $null),
            (New-CcodProbeBridgeInvocation -Proof $false -TargetGate '782640499')
        )){
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -BridgeInvocation $negative)
            Assert-CcodEqual 'Inspected' $result.outcome 'completed renderer negative remains a completed observation'
            Assert-CcodEqual 'RendererRepairRequired' $result.safeState 'completed renderer negative requests repair'
            Assert-CcodEqual $null $result.probes 'renderer negative publishes no raw probe'
        }
    }

    Invoke-CcodTest 'classifies a stale persisted package against the live package without clearing state or keys' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $status=New-CcodEngineActiveStatus -RuntimeId 'runtime-old'
        $state=New-CcodInspectionState -Status $status -VerifiedPackages (New-CcodEngineVerifiedPackages -RuntimeId 'runtime-old')
        $live=New-CcodPackageIdentity;$live.FullName='OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0';$live.Version='2.0.0.0'
        $counts=[pscustomobject]@{Read=0;Package=0;Node=0;Invoke=0;List=0;Match=0;Persisted=0}
        $before=$state|ConvertTo-Json -Depth 20 -Compress
        $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId 'b364b7ed-0f47-435c-849a-5d4758031d46') -Paths $paths -Adapters (New-CcodInspectionAdapters -InspectionState $state -PackageIdentity $live -PreProcesses @($special) -Counters $counts)
        Assert-CcodEqual 'Error' $result.outcome 'stale package status does not authorize a persisted special'
        Assert-CcodEqual 'CCOD_STATE_STALE_PACKAGE' $result.error.code 'stale package status has one sanitized allowlisted diagnostic'
        Assert-CcodEqual 0 ($counts.Node+$counts.Invoke+$counts.List+$counts.Match) 'stale package stops before live process or Node activity'
        Assert-CcodEqual $before ($state|ConvertTo-Json -Depth 20 -Compress) 'stale package leaves persisted status and verified keys intact'
        Assert-CcodEqual $null $result.logFile 'read-only Inspect never writes a stale-package diagnostic'
    }

    Invoke-CcodTest 'fails Inspect provenance closed before Node for every stale or unauthorized tuple' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $status=New-CcodEngineActiveStatus -RuntimeId 'runtime-old'
        $cases=[ordered]@{
            MissingKey=[pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{}}
            WrongKey=(New-CcodEngineVerifiedPackages -RuntimeId 'runtime-other')
        }
        foreach($spec in @(
            [pscustomobject]@{Name='WrongPackage';Field='packageFullName';Value='OpenAI.Codex_DIFFERENT'},
            [pscustomobject]@{Name='WrongVersion';Field='packageVersion';Value='2.0.0.0'},
            [pscustomobject]@{Name='WrongHash';Field='appAsarSha256';Value=('b'*64)},
            [pscustomobject]@{Name='WrongRuntime';Field='runtimeId';Value='runtime-other'},
            [pscustomobject]@{Name='FailedOutcome';Field='dynamicOutcome';Value='Failed'},
            [pscustomobject]@{Name='NotRunProbe';Field='probeState';Value='NotRun'},
            [pscustomobject]@{Name='InvalidProbe';Field='probeState';Value='Invalid'},
            [pscustomobject]@{Name='NativeStatic';Field='staticClassification';Value='NativeModulePresent'},
            [pscustomobject]@{Name='UnknownStatic';Field='staticClassification';Value='UnknownOrIncompatible'}
        )){
            $store=New-CcodEngineVerifiedPackages -RuntimeId 'runtime-old'
            $key='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-old'
            $store.packages.PSObject.Properties[$key].Value.($spec.Field)=$spec.Value
            $cases[$spec.Name]=$store
        }
        $caseDrift=New-CcodEngineVerifiedPackages -RuntimeId 'runtime-old';$exactKey='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-old';$record=$caseDrift.packages.PSObject.Properties[$exactKey].Value
        $caseDrift.packages.PSObject.Properties.Remove($exactKey);$caseDrift.packages|Add-Member -NotePropertyName $exactKey.ToUpperInvariant() -NotePropertyValue $record
        $cases['CaseDriftKey']=$caseDrift
        foreach($case in $cases.GetEnumerator()){
            $counts=[pscustomobject]@{Read=0;Package=0;Node=0;Invoke=0;List=0;Match=0;Persisted=0}
            $state=New-CcodInspectionState -Status $status -VerifiedPackages $case.Value
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -InspectionState $state -PreProcesses @($special) -Counters $counts)
            Assert-CcodEqual 'Error' $result.outcome "$($case.Name) provenance fails closed"
            Assert-CcodTrue (@('CCOD_STATE_BLOCKED','CCOD_VERIFIED_PACKAGES_INVALID') -ccontains $result.error.code) "$($case.Name) uses an existing state classification"
            Assert-CcodEqual 0 $counts.Invoke "$($case.Name) provenance fails before Node"
            Assert-CcodEqual 0 $counts.List "$($case.Name) provenance fails before process observation"
            Assert-CcodEqual $null $result.logFile "$($case.Name) Inspect error performs no diagnostic write"
        }
    }

    Invoke-CcodTest 'requires exact pre and post probe roots and only reduces a natural exit safely' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $ordinary=New-CcodEngineSnapshot
        $debug=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -RendererPort 42001 -MainPort 42002
        $secondSpecial=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Special -RendererPort 42001 -MainPort 42002
        foreach($preCase in @(
            [pscustomobject]@{Processes=@($special,$ordinary)},
            [pscustomobject]@{Processes=@($special,$debug)},
            [pscustomobject]@{Processes=@($special,$secondSpecial)}
        )){
            $counts=[pscustomobject]@{Read=0;Package=0;Node=0;Invoke=0;List=0;Match=0;Persisted=0}
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses $preCase.Processes -Counters $counts)
            Assert-CcodEqual 'Error' $result.outcome 'mixed or multiple pre-probe roots fail closed'
            Assert-CcodEqual 0 $counts.Invoke 'pre-probe root ambiguity fails before Node'
        }

        $noCodex=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -PostProcesses @())
        Assert-CcodEqual 'NoCodex' $noCodex.safeState 'natural post-probe exit with no root reduces to NoCodex'
        $oneOrdinary=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -PostProcesses @($ordinary))
        Assert-CcodEqual 'OrdinaryRunning' $oneOrdinary.safeState 'natural post-probe replacement with one ordinary reduces safely'
        Assert-CcodEqual 100 $oneOrdinary.source.pid 'natural ordinary identity is returned'
        foreach($mainCode in @('OPEN','TIMEOUT')){
            $negativeMain=New-CcodProbeBridgeInvocation -MainCode $mainCode
            $exited=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -PostProcesses @() -BridgeInvocation $negativeMain)
            Assert-CcodEqual 'NoCodex' $exited.safeState "$mainCode is stale after the exact special naturally exits"
            Assert-CcodEqual 'Inspected' $exited.outcome "$mainCode does not override authoritative no-root re-enumeration"
            $ordinaryAfter=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -PostProcesses @($ordinary) -BridgeInvocation $negativeMain)
            Assert-CcodEqual 'OrdinaryRunning' $ordinaryAfter.safeState "$mainCode is stale after one exact ordinary replacement"
            Assert-CcodEqual 100 $ordinaryAfter.source.pid "$mainCode ordinary reduction returns the exact source"
        }

        $pidReuse=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        foreach($postCase in @(
            [pscustomobject]@{Processes=@($pidReuse)},
            [pscustomobject]@{Processes=@($ordinary,$debug)},
            [pscustomobject]@{Processes=@($debug)},
            [pscustomobject]@{Processes=@($special,$ordinary)},
            [pscustomobject]@{Processes=@($secondSpecial)}
        )){
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -PostProcesses $postCase.Processes)
            Assert-CcodEqual 'Error' $result.outcome 'post-probe reuse replacement or ambiguity fails closed'
            Assert-CcodEqual $null $result.logFile 'post-probe Inspect uncertainty writes no diagnostics'
        }
    }

    Invoke-CcodTest 'keeps main and operational probe failures out of renderer repair evidence' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        foreach($mainCode in @('OPEN','TIMEOUT')){
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -BridgeInvocation (New-CcodProbeBridgeInvocation -MainCode $mainCode))
            Assert-CcodEqual 'CCOD_MAIN_INSPECTOR_OPEN' $result.error.code "$mainCode main observation is an error"
            Assert-CcodEqual 'Error' $result.safeState "$mainCode never requests renderer repair"
        }
        foreach($invocation in @(
            [pscustomobject][ordered]@{ExitCode=1;Stdout='{"ok":false,"error":{"code":"DISCOVERY_FAILED"}}';Stderr=''},
            [pscustomobject][ordered]@{ExitCode=0;Stdout='';Stderr=''},
            [pscustomobject][ordered]@{ExitCode=0;Stdout='{}';Stderr=''},
            [pscustomobject][ordered]@{ExitCode=0;Stdout='{"ok":true,"protocolVersion":1,"main":{"inspectorPortClosed":{"confirmed":true,"code":"ECONNREFUSED"}},"renderer":{"targetUrl":"app://-/index.html","probe":{"proof":true,"targetGate":"wrong"}}}';Stderr=''}
        )){
            $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters (New-CcodInspectionAdapters -PreProcesses @($special) -BridgeInvocation $invocation)
            Assert-CcodEqual 'Error' $result.outcome 'Node transport framing or evaluation failure stays operational'
            Assert-CcodEqual 'Error' $result.safeState 'operational failure never becomes renderer repair evidence'
        }
    }

    Invoke-CcodTest 'only the exact Stopped receipt authorizes special launch' {
        foreach($outcome in @('SourceExited','IdentityChanged','StopUnconfirmed')) {
            $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
            $source=New-CcodEngineSnapshot
            $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($source) -StopOutcome $outcome -Counters $counters)
            Assert-CcodEqual 0 $counters.SpecialStart "$outcome never starts special"
            Assert-CcodTrue (@('NoAction','Error') -ccontains $result.outcome) "$outcome returns a non-activated outcome"
        }
    }

    Invoke-CcodTest 'applies the exact journal-before-external-action order and returns validated evidence' {
        $events=[Collections.Generic.List[string]]::new()
        $source=New-CcodEngineSnapshot
        $adapters=New-CcodEngineAdapters -Processes @($source) -Events $events
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'StaticProbe,IntentWritten,StopRequested,StopProcess,OrdinaryStopped,SpecialLaunchRequested,StartSpecial,SpecialStarted,InvokeNode,Validated,WriteStatus,WriteVerified,Complete:Activated' ($events -join ',') 'journal checkpoints precede each external action'
        Assert-CcodEqual 'Activated' $result.outcome 'successful apply is activated'
        Assert-CcodEqual 'SpecialValidated' $result.safeState 'successful apply requires full proof'
        Assert-CcodEqual $true $result.probes.main.inspectorPortClosed.confirmed 'main refusal evidence is retained'
        Assert-CcodEqual $true $result.probes.renderer.newDocumentScriptInstalled 'future renderer documents are covered'
        Assert-CcodEqual '782640499' $result.probes.renderer.probe.targetGate 'exact gate proof is retained'
        Assert-CcodTrue (($result.probes|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'payloadReport') 'raw main payload reports never enter the public result envelope'
        Assert-CcodEngineResultContract $result '5f496d99-c839-4458-a6a2-d37ea1afdbda' 'successful apply'
    }

    Invoke-CcodTest 'selects the External renderer preferred renderer port when no explicit renderer port is requested' {
        $source=New-CcodEngineSnapshot
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($source))
        Assert-CcodEqual 9335 $result.special.rendererPort 'External renderer preferred renderer port is selected'
        Assert-CcodEqual 41002 $result.special.mainPort 'main Inspector remains distinct'
    }

    Invoke-CcodTest 'falls back to a dynamic renderer port when the External renderer port is unavailable' {
        $source=New-CcodEngineSnapshot
        $startedRenderer=[pscustomobject]@{Value=$null}
        $adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.GetPreferredRendererPort={param($Excluded)$null}
        $adapters.GetPort={param($Excluded)if(@($Excluded) -contains 41001){41002}else{41001}}
        $adapters.StartSpecial={
            param($RendererPort,$MainPort,$TimeoutMilliseconds)
            $startedRenderer.Value=$RendererPort
            [pscustomobject]@{Outcome='Started';Snapshot=(New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort $RendererPort -MainPort $MainPort);Process=[pscustomobject]@{Id=201}}
        }.GetNewClosure()
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $result.outcome 'unavailable shared port still activates with a dynamic port'
        Assert-CcodEqual 41001 $result.special.rendererPort 'dynamic renderer port is selected after shared-port rejection'
        Assert-CcodTrue ($startedRenderer.Value -ne 9335) 'StartSpecial never receives the unavailable External renderer port'
    }

    Invoke-CcodTest 'excludes an explicit main port before selecting the External renderer renderer port' {
        $source=New-CcodEngineSnapshot
        $preferred=[pscustomobject]@{Excluded=$null;Calls=0}
        $adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.GetPreferredRendererPort={
            param($Excluded)
            $preferred.Calls++;$preferred.Excluded=@($Excluded)
            if(@($Excluded) -contains 9335){$null}else{9335}
        }.GetNewClosure()
        $adapters.GetPort={param($Excluded)if(@($Excluded) -contains 9335){41001}else{throw 'dynamic renderer must exclude explicit main port'}}
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true -MainPort 9335) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $result.outcome 'explicit main port remains usable when it matches External renderer preference'
        Assert-CcodEqual 1 $preferred.Calls 'preferred renderer adapter is called once'
        Assert-CcodEqual 9335 $preferred.Excluded[0] 'preferred renderer adapter excludes the explicit main port'
        Assert-CcodEqual 41001 $result.special.rendererPort 'dynamic renderer fallback avoids the explicit main port'
        Assert-CcodEqual 9335 $result.special.mainPort 'explicit main port remains unchanged'
    }

    Invoke-CcodTest 'does not call the preferred renderer adapter for an explicit renderer port' {
        $source=New-CcodEngineSnapshot
        $preferred=[pscustomobject]@{Calls=0}
        $adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.GetPreferredRendererPort={param($Excluded)$preferred.Calls++;9335}.GetNewClosure()
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true -RendererPort 41001 -MainPort 41002) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $result.outcome 'explicit renderer and main ports retain existing behavior'
        Assert-CcodEqual 0 $preferred.Calls 'explicit renderer does not call the preferred renderer adapter'
    }

    Invoke-CcodTest 'passes the exact request timeout through every real orchestrator parser child boundary' {
        $timeout=43210
        $source=New-CcodEngineSnapshot
        $applyAdapters=New-CcodEngineAdapters -Processes @($source)
        $applyArguments=[Collections.Generic.List[string]]::new()
        $applyAdapters.InvokeNode={param($NodePath,$Arguments)$applyArguments.Add(($Arguments -join ','));Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $apply=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TimeoutMilliseconds $timeout) -Paths $paths -Adapters $applyAdapters

        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $repairAdapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special)
        $repairArguments=[Collections.Generic.List[string]]::new()
        $repairAdapters.InvokeNode={param($NodePath,$Arguments)$repairArguments.Add(($Arguments -join ','));Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $repair=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer -TimeoutMilliseconds $timeout) -Paths $paths -Adapters $repairAdapters

        $replayAdapters=New-CcodEngineAdapters -Processes @($special)
        $replayArguments=[Collections.Generic.List[string]]::new()
        $replayAdapters.InvokeNode={param($NodePath,$Arguments)$replayArguments.Add(($Arguments -join ','));Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $replay=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TimeoutMilliseconds $timeout) -Paths $paths -Transition (New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial) -Adapters $replayAdapters

        Assert-CcodEqual 'Activated' $apply.outcome 'Apply real parser child accepts the full bridge command'
        Assert-CcodEqual 'NoAction' $repair.outcome 'Repair real parser child accepts the renderer command'
        Assert-CcodEqual 'NoAction' $replay.outcome 'replay real parser child accepts the renderer command'
        foreach($captured in @($applyArguments[0],$repairArguments[0],$replayArguments[0])){
            Assert-CcodTrue ($captured -cmatch "--timeout-ms,$timeout(?:,|$)") 'each bridge command carries the exact request timeout once'
            Assert-CcodEqual 1 ([regex]::Matches($captured,'(?:^|,)--timeout-ms(?:,|$)').Count) 'each bridge command contains one timeout option'
        }
    }

    Invoke-CcodTest 'accepts 120 seconds for the bridge while capping process-control calls at 60 seconds' {
        $source=New-CcodEngineSnapshot
        $captured=[pscustomobject]@{Stop=$null;Start=$null;Bridge=$null}
        $adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$captured.Stop=$TimeoutMilliseconds;[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$captured.Start=$TimeoutMilliseconds;[pscustomobject]@{Outcome='Started';Snapshot=(New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort $RendererPort -MainPort $MainPort);Process=[pscustomobject]@{Id=201}}}.GetNewClosure()
        $adapters.InvokeNode={param($NodePath,$Arguments)$captured.Bridge=@($Arguments);Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TimeoutMilliseconds 120000) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $result.outcome '120-second public timeout reaches a valid bridge result'
        Assert-CcodEqual 60000 $captured.Stop 'source stop stays inside the ProcessControl 60000ms API limit'
        Assert-CcodEqual 60000 $captured.Start 'special start stays inside the ProcessControl 60000ms API limit'
        Assert-CcodTrue (($captured.Bridge -join ',') -cmatch '--timeout-ms,120000(?:,|$)') 'bridge receives the full 120-second value'

        $emptyInspection=New-CcodInspectionState -Status ([pscustomobject]@{schemaVersion=1;session=$null}) -VerifiedPackages ([pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{}})
        $tooLarge=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TimeoutMilliseconds 120000) -Paths $paths -Adapters (New-CcodInspectionAdapters -InspectionState $emptyInspection)
        Assert-CcodEqual 'Inspected' $tooLarge.outcome '120000 is accepted by the shared request contract'
        $invalid=New-CcodEngineRequest;$invalid.timeoutMilliseconds=120001
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' (Invoke-CcodInspectSession -Request $invalid -Paths $paths -Adapters @{ReadState={throw 'must not run'}}).error.code '120001 is rejected before adapters'
    }

    Invoke-CcodTest 'repairs only the identity-bound stale root and blocks disappearance mismatch or ambiguity before launch' {
        $probe=New-CcodEngineProbe
        $probe.PackageFullName='OpenAI.Codex_26.814.5517.0_x64__2p2nqsd0c76g0';$probe.PackageVersion='26.814.5517.0'
        $probe.ExecutablePath='C:\Program Files\WindowsApps\OpenAI.Codex_26.814.5517.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        $old=New-CcodEngineSnapshot -Pid 4596 -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $old.Path='C:\Program Files\WindowsApps\OpenAI.Codex_26.814.5167.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        $old.CommandLine='"' + $old.Path + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $child=New-CcodEngineSnapshot -Pid 4597 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z' -Mode Unrelated -ParentPid 4596
        $child.Path=$old.Path;$child.PackageFamilyName=$old.PackageFamilyName;$child.CommandLine='"' + $child.Path + '" --type=renderer'
        $events=[Collections.Generic.List[string]]::new();$state=[pscustomobject]@{AliveByPid=@{4596=$old;4597=$child};Waits=0;Stops=0;Starts=0;Finds=0};$snapshotFactory=${function:New-CcodEngineSnapshot}
        $adapters=New-CcodEngineAdapters -Probe $probe -Processes @($old,$child) -Events $events
        $adapters.FindStalePackageRoot={param($Package,$StatusEvidence)$state.Finds++;if($state.Finds -eq 1){[pscustomobject][ordered]@{Outcome='Confirmed';Snapshot=$old}}else{[pscustomobject][ordered]@{Outcome='NoCandidate';Snapshot=$null}}}.GetNewClosure()
        $adapters.GetStaleTree={param($Root,$Package)@($child,$old)}.GetNewClosure()
        $adapters.GetStaleProcess={param($Pid,$Package)if($state.AliveByPid.ContainsKey([int]$Pid)){$state.AliveByPid[[int]$Pid]}else{$null}}.GetNewClosure()
        $adapters.RequestStaleGracefulClose={param($Expected,$Package)$events.Add('GracefulClose');[pscustomobject]@{Outcome='Requested';Snapshot=$Expected}}.GetNewClosure()
        $adapters.WaitStaleProcessExit={param($Expected,$Package,$TimeoutMilliseconds)$state.Waits++;$events.Add('WaitExit');[pscustomobject]@{Outcome='StillRunning';Snapshot=$Expected}}.GetNewClosure()
        $adapters.StopStaleProcess={param($Expected,$Package,$TimeoutMilliseconds)$state.Stops++;$events.Add("StopStale:$($Expected.Pid)");$state.AliveByPid.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$events.Add("Port:$Port");$true}.GetNewClosure()
        $adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$state.Starts++;$events.Add('StartSpecial');[pscustomobject]@{Outcome='Started';Snapshot=(& $snapshotFactory -Pid 201 -Mode Unrelated -RendererPort $RendererPort -MainPort $MainPort);Process=[pscustomobject]@{Id=201}}}.GetNewClosure()
        $activated=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -ExistingOnly $true) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $activated.outcome 'one exact old-package remote root is closed before launch'
        Assert-CcodEqual 4596 $activated.source.pid 'successful repair remains correlated to the exact supervisor-observed stale lifecycle'
        Assert-CcodEqual 'GracefulClose,WaitExit,StopStale:4597,StopStale:4596,Port:41001,Port:41002,StartSpecial' (($events | Where-Object { $_ -match '^(GracefulClose|WaitExit|StopStale:|Port:|StartSpecial)' }) -join ',') 'child-first exact tree closure and both port refusals precede special launch'
        Assert-CcodEqual 2 $state.Stops 'every surviving recorded tree member is stopped only after the graceful wait'

        $survivingEvents=[Collections.Generic.List[string]]::new();$survivingState=[pscustomobject]@{AliveByPid=@{4596=$old;4597=$child}}
        $survivingAdapters=New-CcodEngineAdapters -Probe $probe -Processes @($old,$child) -Events $survivingEvents
        $survivingAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)[pscustomobject]@{Outcome='Confirmed';Snapshot=$old}}.GetNewClosure();$survivingAdapters.GetStaleTree={param($Root,$Package)@($child,$old)}.GetNewClosure()
        $survivingAdapters.GetStaleProcess={param($Pid,$Package)if($survivingState.AliveByPid.ContainsKey([int]$Pid)){$survivingState.AliveByPid[[int]$Pid]}else{$null}}.GetNewClosure()
        $survivingAdapters.RequestStaleGracefulClose={param($Expected,$Package)[pscustomobject]@{Outcome='NotRequested';Snapshot=$Expected}}
        $survivingAdapters.StopStaleProcess={param($Expected,$Package,$TimeoutMilliseconds)if($Expected.Pid -eq 4596){$survivingState.AliveByPid.Remove(4596)};[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $survivingAdapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$survivingEvents.Add('StartSpecial');throw 'must not start'}.GetNewClosure()
        $surviving=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId 'a92ec482-6dcf-4b9a-af19-18d9bd4b7ec1') -Paths $paths -Adapters $survivingAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_UNPROVEN' $surviving.error.code 'a recorded stale child that remains alive blocks special launch'
        Assert-CcodTrue ($survivingEvents -cnotcontains 'StartSpecial') 'surviving stale child never permits a second remote server'

        $portEvents=[Collections.Generic.List[string]]::new();$portState=[pscustomobject]@{AliveByPid=@{4596=$old}}
        $portAdapters=New-CcodEngineAdapters -Probe $probe -Processes @($old) -Events $portEvents
        $portAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)[pscustomobject]@{Outcome='Confirmed';Snapshot=$old}}.GetNewClosure();$portAdapters.GetStaleTree={param($Root,$Package)@($old)}.GetNewClosure()
        $portAdapters.GetStaleProcess={param($Pid,$Package)if($portState.AliveByPid.ContainsKey([int]$Pid)){$portState.AliveByPid[[int]$Pid]}else{$null}}.GetNewClosure()
        $portAdapters.RequestStaleGracefulClose={param($Expected,$Package)[pscustomobject]@{Outcome='NotRequested';Snapshot=$Expected}}
        $portAdapters.StopStaleProcess={param($Expected,$Package,$TimeoutMilliseconds)$portState.AliveByPid.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $portAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$Port -ne 41002}.GetNewClosure();$portAdapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$portEvents.Add('StartSpecial');throw 'must not start'}.GetNewClosure()
        $openPort=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId '55a91c89-723d-4bd1-aac0-a0f1b9a2a9fc') -Paths $paths -Adapters $portAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_UNPROVEN' $openPort.error.code 'a stale remote port that remains open blocks special launch'
        Assert-CcodTrue ($portEvents -cnotcontains 'StartSpecial') 'open stale remote port never permits a second server'

        $other=$old|Select-Object *;$other.Pid=4597;$other.CreationTimeUtc='2030-02-03T04:00:01.0000000Z'
        $ambiguousEvents=[Collections.Generic.List[string]]::new();$ambiguousAdapters=New-CcodEngineAdapters -Probe $probe -Processes @($old,$other) -Events $ambiguousEvents
        $ambiguousAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)[pscustomobject][ordered]@{Outcome='Ambiguous';Snapshot=$null}}.GetNewClosure()
        $ambiguous=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId '8394cc7a-69dc-4da0-b229-6fcffb32ec50') -Paths $paths -Adapters $ambiguousAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_AMBIGUOUS' $ambiguous.error.code 'multiple stale same-family roots block special launch'
        Assert-CcodTrue ($ambiguousEvents -cnotcontains 'StartSpecial') 'ambiguity never launches a second special root'

        $missingEvents=[Collections.Generic.List[string]]::new();$missingAdapters=New-CcodEngineAdapters -Probe $probe -Events $missingEvents
        $missingAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)[pscustomobject][ordered]@{Outcome='NoCandidate';Snapshot=$null}}
        $missing=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId 'b36071ed-9135-418f-901d-46e657e4277d') -Paths $paths -Adapters $missingAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_UNPROVEN' $missing.error.code 'an exact candidate that disappears between observation and worker rescan is unproven'
        Assert-CcodTrue ($missingEvents -cnotcontains 'StartSpecial') 'a disappeared stale lifecycle never becomes source-less launch permission'

        $changed=$old|Select-Object *;$changed.CreationTimeUtc='2030-02-03T04:00:09.0000000Z'
        $changedEvents=[Collections.Generic.List[string]]::new();$changedAdapters=New-CcodEngineAdapters -Probe $probe -Events $changedEvents
        $changedAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)[pscustomobject][ordered]@{Outcome='Confirmed';Snapshot=$changed}}.GetNewClosure()
        $changed=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId '3a17e2dc-6f3c-4bb7-ad4f-7d0ea20a54e4') -Paths $paths -Adapters $changedAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_UNPROVEN' $changed.error.code 'a worker rescan cannot substitute a different stale lifecycle for the requested one'
        Assert-CcodTrue ($changedEvents -cnotcontains 'StartSpecial') 'mismatched stale request identity blocks before launch'

        $supervisorEvents=[Collections.Generic.List[string]]::new();$supervisorAdapters=New-CcodEngineAdapters -Probe $probe -Events $supervisorEvents
        $supervisorAdapters.GetSupervisorProcess={param($ProcessId)[pscustomobject][ordered]@{Pid=[int]$ProcessId;CreationTimeUtc='2030-02-03T03:00:01.0000000Z';SessionId='1'}}
        $supervisorAdapters.FindStalePackageRoot={throw 'must not rescan stale roots for a replaced supervisor'}
        $supervisorMismatch=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId 'b3f60f6a-672e-4daf-b5d7-44932c74e8cd') -Paths $paths -Adapters $supervisorAdapters
        Assert-CcodEqual 'CCOD_SOURCE_CHANGED' $supervisorMismatch.error.code 'repair authority is bound to live supervisor PID and creation time'
        Assert-CcodEqual 0 $supervisorEvents.Count 'supervisor replacement blocks before state process or launch activity'

        $preActionGoneEvents=[Collections.Generic.List[string]]::new();$preActionGoneState=[pscustomobject]@{Finds=0}
        $preActionGoneAdapters=New-CcodEngineAdapters -Probe $probe -Events $preActionGoneEvents
        $preActionGoneAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)$preActionGoneState.Finds++;if($preActionGoneState.Finds -eq 1){[pscustomobject][ordered]@{Outcome='Confirmed';Snapshot=$old}}else{[pscustomobject][ordered]@{Outcome='NoCandidate';Snapshot=$null}}}.GetNewClosure()
        $preActionGoneAdapters.GetStaleTree={param($Root,$Package)@($old)}.GetNewClosure()
        $preActionGoneAdapters.RequestStaleGracefulClose={param($Expected,$Package)$preActionGoneEvents.Add('GracefulClose:SourceExited');[pscustomobject]@{Outcome='SourceExited';Snapshot=$null}}.GetNewClosure()
        $preActionGoneAdapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$preActionGoneEvents.Add('StartSpecial');throw 'must not start'}.GetNewClosure()
        $preActionGone=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId 'f84d6806-f44e-4d92-a2bf-9ad5ebd90cd4') -Paths $paths -Adapters $preActionGoneAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_UNPROVEN' $preActionGone.error.code 'root disappearance before an exact close signal is unproven'
        Assert-CcodTrue ($preActionGoneEvents -cnotcontains 'StartSpecial') 'pre-action root disappearance never authorizes special launch'

        $reusedRoot=$old|Select-Object *;$reusedRoot.CreationTimeUtc='2030-02-03T04:00:09.0000000Z'
        $changedRootEvents=[Collections.Generic.List[string]]::new();$changedRootState=[pscustomobject]@{Finds=0}
        $changedRootAdapters=New-CcodEngineAdapters -Probe $probe -Events $changedRootEvents
        $changedRootAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)$changedRootState.Finds++;if($changedRootState.Finds -eq 1){[pscustomobject][ordered]@{Outcome='Confirmed';Snapshot=$old}}else{[pscustomobject][ordered]@{Outcome='NoCandidate';Snapshot=$null}}}.GetNewClosure()
        $changedRootAdapters.GetStaleTree={param($Root,$Package)@($old)}.GetNewClosure()
        $changedRootAdapters.RequestStaleGracefulClose={param($Expected,$Package)[pscustomobject]@{Outcome='NotRequested';Snapshot=$Expected}}
        $changedRootAdapters.GetStaleProcess={param($ProcessId,$Package)$reusedRoot}.GetNewClosure()
        $changedRootAdapters.StopStaleProcess={param($Expected,$Package,$TimeoutMilliseconds)$changedRootEvents.Add('StopStale');throw 'PID-reused root must not be signaled'}.GetNewClosure()
        $changedRootAdapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$changedRootEvents.Add('StartSpecial');throw 'must not start'}.GetNewClosure()
        $changedRoot=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId '356f44c9-f600-4899-85eb-85411631a40e') -Paths $paths -Adapters $changedRootAdapters
        Assert-CcodEqual 'CCOD_STALE_PACKAGE_UNPROVEN' $changedRoot.error.code 'root PID reuse before a verified terminate action is unproven'
        Assert-CcodEqual 0 @($changedRootEvents|Where-Object{$_ -in @('StopStale','StartSpecial')}).Count 'PID-reused root is neither signaled nor hidden by launch'

        $recoveryState=[pscustomobject]@{Finds=0};$recoveryAdapters=New-CcodEngineAdapters -Probe $probe -Processes @($old)
        $recoveryAdapters.FindStalePackageRoot={param($Package,$StatusEvidence)$recoveryState.Finds++;if($recoveryState.Finds -eq 1){[pscustomobject][ordered]@{Outcome='Confirmed';Snapshot=$old}}else{[pscustomobject][ordered]@{Outcome='NoCandidate';Snapshot=$null}}}.GetNewClosure()
        $recoveryAdapters.GetStaleTree={param($Root,$Package)@($old)}.GetNewClosure()
        $recoveryAdapters.RequestStaleGracefulClose={param($Expected,$Package)[pscustomobject]@{Outcome='Requested';Snapshot=$Expected}}
        $recoveryAdapters.WaitStaleProcessExit={param($Expected,$Package,$TimeoutMilliseconds)[pscustomobject]@{Outcome='SourceExited';Snapshot=$null}}
        $recoveryAdapters.GetStaleProcess={param($ProcessId,$Package)$null}
        $recoveryAdapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)[pscustomobject]@{Outcome='Failed';Snapshot=$null;Process=$null}}
        $recovered=Invoke-CcodRepairStaleSession -Request (New-CcodEngineRequest -Action RepairStale -Source $old -TransactionId '1407e886-5a42-493f-b61a-2eb27b588fd1') -Paths $paths -Adapters $recoveryAdapters
        Assert-CcodEqual 'Recovered' $recovered.outcome 'post-closure activation failure still performs the existing ordinary recovery'
        Assert-CcodEqual 301 $recovered.source.pid 'recovered result source describes the proven ordinary recovery, not the closed stale root'
    }

    Invoke-CcodTest 'discovers one existing ordinary source and rejects manual Start root ambiguity' {
        $ordinary=New-CcodEngineSnapshot
        $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($ordinary) -Events $events -Counters $counters
        $activated=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $activated.outcome 'one existing ordinary root converts to special'
        Assert-CcodEqual 100 $activated.source.pid 'the discovered ordinary identity is retained in the result'
        Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,StopRequested,StopProcess,OrdinaryStopped') 'discovered ordinary root is journaled and exactly stopped before launch'

        $second=New-CcodEngineSnapshot -Pid 101 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z'
        $multipleCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $multiple=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false -TransactionId '30fc56b0-547b-4b60-996a-d82b7301384c') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($ordinary,$second) -Counters $multipleCounters)
        Assert-CcodEqual 'CCOD_SOURCE_AMBIGUOUS' $multiple.error.code 'multiple ordinary roots cannot be silently reduced to source null'
        Assert-CcodEqual 0 $multipleCounters.SpecialStart 'ambiguous ordinary roots never start special'

        $debug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $debugCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $ambiguous=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false -TransactionId 'b56470ad-948a-4df7-b5f2-04a4df86a256') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($debug) -Counters $debugCounters)
        Assert-CcodEqual 'CCOD_SOURCE_AMBIGUOUS' $ambiguous.error.code 'an existing debug root cannot be treated as a closed app'
        Assert-CcodEqual 0 $debugCounters.SpecialStart 'debug ambiguity never starts another special root'

        $foreignSessionCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $foreignSessionAdapters=New-CcodEngineAdapters -Processes @() -Counters $foreignSessionCounters
        $foreignSessionAdapters.CurrentIdentity={[pscustomobject][ordered]@{SessionId='2';UserSid='S-1-5-21-test'}}
        $foreignSession=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false -TransactionId '6e053d2c-80a3-4d47-8a43-9d238f0d84b1') -Paths $paths -Adapters $foreignSessionAdapters
        Assert-CcodEqual 'CCOD_SOURCE_AMBIGUOUS' $foreignSession.error.code 'manual Start cannot target a supervisor identity from another Windows session'
        Assert-CcodEqual 0 $foreignSessionCounters.SpecialStart 'session identity mismatch never starts special'

        $foreignSource=New-CcodEngineSnapshot;$foreignSource.SessionId=2
        $foreignSourceCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $foreignSourceResult=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $foreignSource -TransactionId '5a543a32-a62e-4e61-ae43-f290080c83d9') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($foreignSource) -Counters $foreignSourceCounters)
        Assert-CcodEqual 'CCOD_SOURCE_CHANGED' $foreignSourceResult.error.code 'an explicit source must belong to the current supervisor session and user'
        Assert-CcodEqual 0 $foreignSourceCounters.SpecialStart 'foreign-session explicit source is never stopped or replaced'
    }

    Invoke-CcodTest 'schema-v2 Apply ignores legacy false preferences when internal package compatibility is healthy' {
        $source=New-CcodEngineSnapshot
        $state=New-CcodEngineState
        $state.AutomationEnabled=$false
        $state.AutomaticCandidateTrialsAllowed=$false
        $state.Settings.automationEnabled=$false
        $state.Settings.candidateCompatibleOptIn=$false
        $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TransactionId '4dd6f31d-874f-49d4-8705-c1813d5a5ae0') -Paths $paths -Adapters (New-CcodEngineAdapters -State $state -Processes @($source) -Events $events -Counters $counters)
        Assert-CcodEqual 'Activated' $result.outcome 'healthy internal compatibility still applies under false migration preferences'
        Assert-CcodEqual 1 $counters.SpecialStart 'false migration preferences do not suppress the schema-v2 operation'
    }

    Invoke-CcodTest 'rejects damaged status before old verified history can authorize Apply' {
        $state=New-CcodEngineState
        $state.StatusRebuildRequired=$true
        $state.AutomaticCandidateTrialsAllowed=$false
        $key='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-1'
        $record=[pscustomobject]@{packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);runtimeId='runtime-1';staticClassification='CandidateCompatible';dynamicOutcome='Succeeded';probeState='Valid';confirmedAtUtc='2030-02-03T04:06:00.0000000Z'}
        $state.VerifiedPackages=[pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{$key=$record}}
        $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false) -Paths $paths -Adapters (New-CcodEngineAdapters -State $state -Events $events -Counters $counters)
        Assert-CcodEqual 'CCOD_STATE_BLOCKED' $result.error.code 'status rebuild is a hard Apply gate even with a historical success'
        Assert-CcodEqual 0 $counters.SpecialStart 'damaged status blocks process actions'
        Assert-CcodTrue (($events -join ',') -cnotmatch 'IntentWritten') 'damaged status blocks journal creation'
    }

    Invoke-CcodTest 'recovers exactly once after each representative post-stop failure and records suppression' {
        foreach($failure in @('Port','Start','Bridge','Status','History')) {
            $events=[Collections.Generic.List[string]]::new();$source=New-CcodEngineSnapshot
            $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0;PortChecks=0;DelayedMs=0}
            $adapters=New-CcodEngineAdapters -Processes @($source) -Events $events -Counters $counters
            $adapters.ListProcesses={ param($StatusEvidence) @() }
            $adapters.Delay={param($Milliseconds)$counters.DelayedMs+=$Milliseconds}.GetNewClosure()
            $baseSet=$adapters.SetTransition
            $adapters.SetTransition={param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)if($NewStage -ceq 'RecoveryLaunchRequested'){$counters.Recover++};& $baseSet $Path $TransactionId $ExpectedStage $NewStage $SpecialIdentity $RecoveryIdentity $RendererPort $MainPort}.GetNewClosure()
            $baseWait=$adapters.WaitPortClosed
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$counters.PortChecks++;& $baseWait $Port $TimeoutMilliseconds}.GetNewClosure()
            switch($failure){
                'Port' {$adapters.GetPort={param($Excluded)$null}}
                'Start' {$adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$counters.SpecialStart++;[pscustomobject]@{Outcome='Failed';Snapshot=$null;Process=$null}}.GetNewClosure()}
                'Bridge' {$adapters.InvokeNode={param($NodePath,$Arguments)$counters.Node++;[pscustomobject][ordered]@{ExitCode=0;Stdout='{}';Stderr=''}}.GetNewClosure()}
                'Status' {$writeCounter=[pscustomobject]@{Count=0};$adapters.WriteStatus={param($StateRoot,$Status,$LiveProbe)$writeCounter.Count++;if($writeCounter.Count -eq 1){throw 'status write failed'};$events.Add('WriteStatus')}.GetNewClosure()}
                'History' {$writeCounter=[pscustomobject]@{Count=0};$adapters.WriteVerified={param($StateRoot,$Verified)$writeCounter.Count++;if($writeCounter.Count -eq 1){throw 'history write failed'};$events.Add('WriteVerified')}.GetNewClosure()}
            }
            $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 1 $counters.Recover "$failure enters Recover exactly once"
            Assert-CcodEqual 1 $counters.OrdinaryStart "$failure launches ordinary at most once after its five-second observation"
            Assert-CcodEqual 'Recovered' $result.outcome "$failure returns a proven recovered outcome"
            Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.suppressionKey)) "$failure returns the durable suppression key"
            if($failure -ceq 'Start'){Assert-CcodEqual 2 $counters.PortChecks 'recorded launch ports are proven refused even when no special PID was committed'}
        }
    }

    Invoke-CcodTest 'recovers an exact special tree child-to-parent and never stops unrelated or PID-reused members' {
        $source=New-CcodEngineSnapshot
        $rootSpecial=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $child=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -ParentPid 201 -RendererPort 41001 -MainPort 41002 -IsTopLevel $false
        $unrelated=New-CcodEngineSnapshot -Pid 999 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $stopped=[Collections.Generic.List[int]]::new();$adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.InvokeNode={param($NodePath,$Arguments)throw 'bridge failed'}
        $adapters.ListProcesses={param($StatusEvidence)@()}
        $adapters.GetTree={param($Root,$StatusEvidence)@($rootSpecial,$child)}.GetNewClosure()
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)switch($ProcessId){201{$rootSpecial}202{$child}999{$unrelated}default{$source}}}.GetNewClosure()
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stopped.Add([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters $adapters
        Assert-CcodEqual '100,202,201' ($stopped -join ',') 'ordinary source stops first and only the verified special tree is then stopped child before parent'
        Assert-CcodEqual 'Recovered' $result.outcome 'exact tree stop proceeds to ordinary recovery'

        $stopped.Clear();$reused=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:06:08.0000000Z' -Mode Unrelated -ParentPid 201 -RendererPort 41001 -MainPort 41002 -IsTopLevel $false
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($ProcessId -eq 202){$reused}elseif($ProcessId -eq 201){$rootSpecial}else{$source}}.GetNewClosure()
        $unsafe=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TransactionId '616a0ad7-27fe-4d08-8556-b5cc7c2bd0b3') -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Error' $unsafe.outcome 'PID reuse makes recovery unsafe'
        Assert-CcodEqual '100' ($stopped -join ',') 'after the authorized source stop no special member is stopped following a child identity mismatch'
    }

    Invoke-CcodTest 'uses fake five-second recovery observation before adoption or one launch' {
        $source=New-CcodEngineSnapshot;$ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'
        $clock=[pscustomobject]@{Delayed=0;Polls=0};$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($source) -Counters $counters
        $adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)[pscustomobject]@{Outcome='Failed';Snapshot=$null;Process=$null}}
        $adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
        $adapters.ListProcesses={param($StatusEvidence)$clock.Polls++;if($clock.Polls -ge 4){@($ordinary)}else{@()}}.GetNewClosure()
        $adopted=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 3000 $clock.Delayed 'ordinary appearing in the fourth poll is adopted after three fake seconds'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'adoption avoids an ordinary launch'
        Assert-CcodEqual 301 $adopted.recovery.pid 'adoption returns the exact ordinary snapshot'

        $clock.Delayed=0;$adapters.ListProcesses={param($StatusEvidence)@()};$launched=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TransactionId '7db414e1-54f3-49a5-b11f-a8a2c266df00') -Paths $paths -Adapters $adapters
        Assert-CcodEqual 5000 $clock.Delayed 'launch occurs only after the full fake five-second absence window'
        Assert-CcodEqual 1 $counters.OrdinaryStart 'ordinary is launched exactly once'
        Assert-CcodEqual 301 $launched.recovery.pid 'launch receipt exact snapshot is journaled'
    }

    Invoke-CcodTest 'replays every normal stage without ever starting special and preserves request correlation' {
        $source=New-CcodEngineSnapshot;$special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        foreach($case in @(
            @{Stage='IntentWritten';Transition=(New-CcodEngineTransition -Stage IntentWritten);Processes=@($source);Expected='NoAction'},
            @{Stage='StopRequested';Transition=(New-CcodEngineTransition -Stage StopRequested);Processes=@($source);Expected='NoAction'},
            @{Stage='OrdinaryStopped';Transition=(New-CcodEngineTransition -Stage OrdinaryStopped);Processes=@();Expected='Recovered'},
            @{Stage='SpecialLaunchRequested';Transition=(New-CcodEngineTransition -Stage SpecialLaunchRequested -WithPorts);Processes=@();Expected='Recovered'},
            @{Stage='SpecialStarted';Transition=(New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial);Processes=@($special);Expected='NoAction'},
            @{Stage='Validated';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);Processes=@($special);Expected='NoAction'},
            @{Stage='RecoveryLaunchRequested';Transition=(New-CcodEngineTransition -Stage RecoveryLaunchRequested -WithPorts -WithSpecial);Processes=@();Expected='Recovered'},
            @{Stage='Recovered';Transition=(New-CcodEngineTransition -Stage Recovered -WithPorts -WithSpecial -WithRecovery);Processes=@((New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'));Expected='Recovered'}
        )){
            $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$clock=[pscustomobject]@{Delayed=0}
            $events=[Collections.Generic.List[string]]::new();$adapters=New-CcodEngineAdapters -Processes $case.Processes -Counters $counters -Events $events
            $adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
            $adapters.ObserveSpecial={param($Transition,$Paths,$TimeoutMilliseconds)
                if($case.Stage -in @('SpecialStarted','Validated')){[pscustomobject]@{Outcome='Confirmed';Snapshot=$special;Candidates=@($special);ConflictOwners=@();Validation='Valid'}}
                else{[pscustomobject]@{Outcome='NoCandidate';Snapshot=$null;Candidates=@();ConflictOwners=@();Validation='Indeterminate'}}
            }.GetNewClosure()
            $request=New-CcodEngineRequest -Action Recover -TransactionId 'a8f08753-4e7a-4466-880a-ae4fcc3b9c59'
            $result=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $case.Transition -Adapters $adapters
            Assert-CcodEqual $case.Expected $result.outcome "$($case.Stage) replay reaches its safe expected outcome"
            Assert-CcodEqual $request.transactionId $result.transactionId "$($case.Stage) replay result keeps request correlation, not the older journal ID"
            Assert-CcodEqual 0 $counters.SpecialStart "$($case.Stage) replay never starts special"
        }
    }

    Invoke-CcodTest 'advances each proven activation crash window through Validated before Activated completion' {
        $candidate=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        foreach($case in @(
            [pscustomobject]@{Name='AfterPid';Transition=(New-CcodEngineTransition -Stage SpecialLaunchRequested -WithPorts);MainClosed=$false;ExpectedMode='full';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='SpecialStartedMainOpen';Transition=(New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial);MainClosed=$false;ExpectedMode='full';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='SpecialStartedMainRefused';Transition=(New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='AfterValidated';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='AfterStatus';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState -Status (New-CcodEngineActiveStatus))},
            [pscustomobject]@{Name='AfterHistory';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState -Status (New-CcodEngineActiveStatus))},
            [pscustomobject]@{Name='AfterCompletion';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState -Status (New-CcodEngineActiveStatus))}
        )){
            if($case.Name -ceq 'AfterHistory'){
                $key='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-1'
                $case.State.VerifiedPackages=[pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{$key=[pscustomobject]@{packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);runtimeId='runtime-1';staticClassification='CandidateCompatible';dynamicOutcome='Succeeded';probeState='Valid';confirmedAtUtc='2030-02-03T04:06:00.0000000Z'}}}
            }
            $events=[Collections.Generic.List[string]]::new();$captured=[pscustomobject]@{Arguments=$null};$adapters=New-CcodEngineAdapters -State $case.State -Processes @($candidate) -Events $events
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)[bool]$case.MainClosed}.GetNewClosure()
            $adapters.InvokeNode={param($NodePath,$Arguments)$captured.Arguments=@($Arguments);Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
            if($case.Transition.stage -ceq 'SpecialLaunchRequested'){$adapters.ObserveSpecial={param($Transition,$Paths,$TimeoutMilliseconds)[pscustomobject]@{Outcome='Confirmed';Snapshot=$candidate;Candidates=@($candidate);ConflictOwners=@();Validation='Indeterminate'}}.GetNewClosure()}
            if($case.Name -ceq 'AfterCompletion'){$adapters.CompleteTransition={param($Path,$LogPath,$TransactionId,$Disposition)$events.Add("Complete:$Disposition");[pscustomobject]@{Outcome='AlreadyCompleted'}}.GetNewClosure()}
            $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Transition $case.Transition -Adapters $adapters
            Assert-CcodEqual 'NoAction' $result.outcome "$($case.Name) re-establishes validated special state"
            Assert-CcodEqual 'SpecialValidated' $result.safeState "$($case.Name) never reports Active without proof"
            Assert-CcodTrue (($captured.Arguments -join ',') -cmatch "--mode,$($case.ExpectedMode)(?:,|$)") "$($case.Name) uses the stage-appropriate bridge mode"
            Assert-CcodTrue (($events -join ',') -cmatch 'WriteStatus,WriteVerified,Complete:Activated$') "$($case.Name) rebuilds status/history before completion"
            if($case.Transition.stage -ceq 'SpecialLaunchRequested'){Assert-CcodTrue (($events -join ',') -cmatch 'SpecialStarted,Validated,WriteStatus') 'after-PID replay durably records both missing stages before Active status'}
            if($case.Transition.stage -ceq 'SpecialStarted'){Assert-CcodTrue (($events -join ',') -cmatch 'Validated,WriteStatus') "$($case.Name) records Validated before Active status"}
        }
    }

    Invoke-CcodTest 'binds replay to the exact journal runtime package name and asar hash before side effects' {
        foreach($field in @('runtimeId','packageFullName','appAsarSha256')){
            $transition=New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial
            switch($field){'runtimeId'{$transition.runtimeId='runtime-old'};'packageFullName'{$transition.packageFullName='OpenAI.Codex_0.9.0.0_x64__2p2nqsd0c76g0'};'appAsarSha256'{$transition.appAsarSha256=('b'*64)}}
            $candidate=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
            $events=[Collections.Generic.List[string]]::new();$counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
            $adapters=New-CcodEngineAdapters -Processes @($candidate) -Events $events -Counters $counts
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
            $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Transition $transition -Adapters $adapters
            Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code "$field mismatch fails closed before replay activity"
            Assert-CcodEqual 0 $counts.Node "$field mismatch invokes no bridge child"
            Assert-CcodTrue (($events -join ',') -cnotmatch 'Validated|WriteStatus|WriteVerified|Complete:') "$field mismatch performs no journal status history or completion write"
        }
    }

    Invoke-CcodTest 'binds recovery replay stages to the exact durable runtime package tuple' {
        foreach($stage in @('RecoveryLaunchRequested','Recovered')){
            foreach($field in @('runtimeId','packageFullName','appAsarSha256')){
                $transition=if($stage -ceq 'Recovered'){
                    New-CcodEngineTransition -Stage Recovered -WithPorts -WithSpecial -WithRecovery
                }else{New-CcodEngineTransition -Stage RecoveryLaunchRequested -WithPorts -WithSpecial}
                switch($field){'runtimeId'{$transition.runtimeId='runtime-old'};'packageFullName'{$transition.packageFullName='OpenAI.Codex_0.9.0.0_x64__2p2nqsd0c76g0'};'appAsarSha256'{$transition.appAsarSha256=('b'*64)}}
                $ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'
                $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
                $adapters=New-CcodEngineAdapters -Processes @($ordinary) -Events $events -Counters $counters
                $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Transition $transition -Adapters $adapters
                Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code "$stage $field mismatch fails closed"
                Assert-CcodEqual 0 $counters.Node "$stage $field mismatch invokes no bridge child"
                Assert-CcodTrue (($events -join ',') -cnotmatch 'WriteStatus|WriteVerified|Complete:') "$stage $field mismatch writes no current-tuple status history or completion"
            }
        }
    }

    Invoke-CcodTest 'replays Recovered side effects idempotently and never archives it as Cancelled' {
        $ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'
        $transition=New-CcodEngineTransition -Stage Recovered -WithPorts -WithSpecial -WithRecovery
        $events=[Collections.Generic.List[string]]::new();$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status (New-CcodEngineActiveStatus)) -Processes @($ordinary) -Events $events
        $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId 'a8f08753-4e7a-4466-880a-ae4fcc3b9c59') -Paths $paths -Transition $transition -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'Recovered replay adopts the journaled ordinary root'
        Assert-CcodEqual 'WriteStatus,WriteVerified,Complete:Recovered' (($events|Where-Object{$_ -in @('WriteStatus','WriteVerified','Complete:Recovered')}) -join ',') 'Recovered replay finishes all idempotent side effects before archival'
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.ignoreKey)) 'Recovered replay returns the durable ignore key'
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.suppressionKey)) 'Recovered replay returns the suppression key'
        Assert-CcodEqual $transition.transactionId $result.recovery.priorTransactionId 'Recovered replay side effects correlate to the journal transaction'

        $missingEvents=[Collections.Generic.List[string]]::new();$missing=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId 'd28e874b-9cb3-4d1e-8fc5-4a9abc2334f9') -Paths $paths -Transition $transition -Adapters (New-CcodEngineAdapters -Processes @() -Events $missingEvents)
        Assert-CcodEqual 'Error' $missing.outcome 'missing Recovered identity remains unproven'
        Assert-CcodTrue (($missingEvents -join ',') -cnotmatch 'Complete:Cancelled') 'Recovered is never archived with the Cancelled disposition'
    }

    Invoke-CcodTest 'uses exact fake primary five seconds plus guard five seconds for StopRequested' {
        $source=New-CcodEngineSnapshot;$clock=[pscustomobject]@{Delayed=0};$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($source) -Counters $counters
        $adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
        $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Transition (New-CcodEngineTransition -Stage StopRequested) -Adapters $adapters
        Assert-CcodEqual 10000 $clock.Delayed 'unchanged source receives primary 5 seconds and independent guard 5 seconds'
        Assert-CcodEqual 'NoAction' $result.outcome 'same live source is kept after both windows'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'guard completion does not launch recovery ordinary'
        Assert-CcodEqual 0 $counters.SpecialStart 'stop replay never starts special'
    }

    Invoke-CcodTest 'schema-v2 Close stops a verified tree child-first without ordinary relaunch' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $child=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -ParentPid 201 -RendererPort 41001 -MainPort 41002 -IsTopLevel $false
        $status=New-CcodEngineActiveStatus;$events=[Collections.Generic.List[string]]::new();$alive=@{201=$special;202=$child}
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special) -Events $events -Counters $counters
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure()
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
        $adapters.ObserveProcessIdentity={param($ProcessId,$ExpectedCreationTimeUtc)if($alive.ContainsKey([int]$ProcessId)){[pscustomobject][ordered]@{Outcome='SameIdentity';Pid=[int]$ProcessId;CreationTimeUtc=[string]$ExpectedCreationTimeUtc}}else{[pscustomobject][ordered]@{Outcome='Absent';Pid=[int]$ProcessId;CreationTimeUtc=$null}}}.GetNewClosure()
        $adapters.GetTree={param($Root,$StatusEvidence)@($special,$child)}.GetNewClosure()
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$events.Add("Stop:$($Expected.Pid)");$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $request=New-CcodEngineRequest -SchemaVersion 2 -Action Close -Source $special -RestartOrdinary $false
        $result=Invoke-CcodCloseSession -Request $request -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $result.outcome 'verified Close reaches the explicit closed outcome'
        Assert-CcodEqual 'Stop:202,Stop:201' ((@($events|Where-Object{$_ -like 'Stop:*'}))-join ',') 'verified Close stops child before root'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'Close never requests ordinary activation'
    }

    Invoke-CcodTest 'proven stale status adopts and closes the unique current ordinary root' {
        $oldStatus = New-CcodEngineActiveStatus -RuntimeId '2.5.19-old'
        $oldStatus.session.codex.pid = 10664
        $oldStatus.session.codex.creationTimeUtc = '2026-08-26T04:49:22.1551350Z'
        $oldStatus.session.codex.packageFullName = 'OpenAI.Codex_26.820.7780.0_x64__2p2nqsd0c76g0'
        $oldStatus.session.codex.packageVersion = '26.820.7780.0'
        $replacement = New-CcodEngineSnapshot -Pid 13948 -CreationTimeUtc '2026-08-27T07:00:17.0000000Z' -Mode Ordinary
        $probe = New-CcodEngineProbe
        $probe.PackageFullName = 'OpenAI.Codex_26.820.9563.0_x64__2p2nqsd0c76g0'
        $probe.PackageVersion = '26.820.9563.0'
        $events = [Collections.Generic.List[string]]::new()
        $alive = @{13948=$replacement}
        $adapters = New-CcodEngineAdapters -State (New-CcodEngineState -Status $oldStatus) -Probe $probe -Processes @($replacement) -Events $events
        $adapters.StaticProbe = { param($NodeCandidates,$CheckerPath) $probe }.GetNewClosure()
        $adapters.ListProcesses = { param($StatusEvidence) @($alive.Values) }.GetNewClosure()
        $adapters.GetProcess = { param($ProcessId,$StatusEvidence) if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null} }.GetNewClosure()
        $adapters.ObserveProcessIdentity = { param($ProcessId,$ExpectedCreationTimeUtc) [pscustomobject][ordered]@{Outcome='Absent';Pid=[int]$ProcessId;CreationTimeUtc=$null} }
        $adapters.GetTree = { param($Root,$StatusEvidence) @($Root) }
        $adapters.StopProcess = { param($Expected,$StatusEvidence,$TimeoutMilliseconds) $events.Add("Stop:$($Expected.Pid)");$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected} }.GetNewClosure()

        $result = Invoke-CcodCloseSession -Request (New-CcodEngineRequest -SchemaVersion 2 -Action Close -RestartOrdinary $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $result.outcome "proven stale status adopts and closes the unique current ordinary root error=$($result.error.code):$($result.error.message)"
        Assert-CcodEqual 'IntentWritten,CloseRequested,Stop:13948,Closed,WriteStatus,Complete:Closed' ($events -join ',') 'journal precedes stop and stale status is cleared only at durable completion'
    }

    Invoke-CcodTest 'stale status replacement remains fail-closed without one strict replacement root and tree' {
        $oldStatus = New-CcodEngineActiveStatus -RuntimeId '2.5.19-old'
        $oldStatus.session.codex.pid = 10664
        $oldStatus.session.codex.creationTimeUtc = '2026-08-26T04:49:22.1551350Z'
        $oldStatus.session.codex.packageFullName = 'OpenAI.Codex_26.820.7780.0_x64__2p2nqsd0c76g0'
        $oldStatus.session.codex.packageVersion = '26.820.7780.0'
        $probe = New-CcodEngineProbe
        $probe.PackageFullName = 'OpenAI.Codex_26.820.9563.0_x64__2p2nqsd0c76g0'
        $probe.PackageVersion = '26.820.9563.0'
        $ordinary = New-CcodEngineSnapshot -Pid 13948 -CreationTimeUtc '2026-08-27T07:00:17.0000000Z' -Mode Ordinary
        $second = New-CcodEngineSnapshot -Pid 13949 -CreationTimeUtc '2026-08-27T07:00:18.0000000Z' -Mode Ordinary
        $missingPort = New-CcodEngineSnapshot -Pid 13950 -CreationTimeUtc '2026-08-27T07:00:19.0000000Z' -Mode Unrelated -RendererPort 42001
        $equalPorts = New-CcodEngineSnapshot -Pid 13951 -CreationTimeUtc '2026-08-27T07:00:20.0000000Z' -Mode Unrelated -RendererPort 42001 -MainPort 42001
        $cases = @(
            @{Name='same native identity';Processes=@($ordinary);Observation=[pscustomobject][ordered]@{Outcome='SameIdentity';Pid=10664;CreationTimeUtc='2026-08-26T04:49:22.1551350Z'}},
            @{Name='native query exception';Processes=@($ordinary);Throw=$true},
            @{Name='invalid native receipt';Processes=@($ordinary);Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null;Extra=$true}},
            @{Name='zero roots';Processes=@();Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null}},
            @{Name='two top-level roots';Processes=@($ordinary,$second);Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null}},
            @{Name='one visible root plus one indeterminate root';Processes=@($ordinary);Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null};EnumerationIncomplete=$true},
            @{Name='debug root missing one port';Processes=@($missingPort);Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null}},
            @{Name='debug root equal ports';Processes=@($equalPorts);Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null}},
            @{Name='empty verified tree';Processes=@($ordinary);Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null};EmptyTree=$true}
        )
        foreach($case in $cases){
            $events=[Collections.Generic.List[string]]::new();$processes=@($case.Processes);$alive=@{};foreach($process in $processes){$alive[[int]$process.Pid]=$process}
            $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $oldStatus) -Probe $probe -Processes $processes -Events $events
            $adapters.StaticProbe={param($NodeCandidates,$CheckerPath)$probe}.GetNewClosure()
            $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure()
            if($case.ContainsKey('EnumerationIncomplete')){
                $visible=@($alive.Values)
                $adapters.ListProcessResult={param($StatusEvidence)[pscustomobject][ordered]@{Outcome='Incomplete';Snapshots=@($visible)}}.GetNewClosure()
            }
            $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
            if($case.Throw){$adapters.ObserveProcessIdentity={param($ProcessId,$ExpectedCreationTimeUtc)throw 'native query failed'}}else{$observation=$case.Observation;$adapters.ObserveProcessIdentity={param($ProcessId,$ExpectedCreationTimeUtc)$observation}.GetNewClosure()}
            if($case.EmptyTree){$adapters.GetTree={param($Root,$StatusEvidence)@()}}
            $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$events.Add("Stop:$($Expected.Pid)");throw 'must not stop'}.GetNewClosure()
            $result=Invoke-CcodCloseSession -Request (New-CcodEngineRequest -SchemaVersion 2 -Action Close -RestartOrdinary $false -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'Error' $result.outcome "$($case.Name) fails closed"
            Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $result.error.code "$($case.Name) returns the exact stable close rejection"
            Assert-CcodEqual '' ($events -join ',') "$($case.Name) performs zero journal status or process mutations"
        }
    }

    Invoke-CcodTest 'rich null never proves tree exit before stop after stop or during final verification' {
        $probe=New-CcodEngineProbe
        $rootProcess=New-CcodEngineSnapshot -Pid 13948 -CreationTimeUtc '2026-08-27T07:00:17.0000000Z' -Mode Ordinary
        foreach($case in @(
            @{Name='pre-stop rich null plus SameIdentity';Stage='Pre';Indeterminate=$false},
            @{Name='post-stop rich null plus SameIdentity';Stage='Post';Indeterminate=$false},
            @{Name='observer indeterminate';Stage='Pre';Indeterminate=$true},
            @{Name='final rich null plus SameIdentity';Stage='Final';Indeterminate=$false}
        )){
            $events=[Collections.Generic.List[string]]::new();$reads=[pscustomobject]@{Count=0};$observations=[pscustomobject]@{Count=0}
            $adapters=New-CcodEngineAdapters -State (New-CcodEngineState) -Probe $probe -Processes @($rootProcess) -Events $events
            $adapters.StaticProbe={param($NodeCandidates,$CheckerPath)$probe}.GetNewClosure()
            $adapters.ListProcesses={param($StatusEvidence)@($rootProcess)}.GetNewClosure()
            $stage=[string]$case.Stage
            $adapters.GetProcess={
                param($ProcessId,$StatusEvidence)
                $reads.Count++
                if($stage -ceq 'Pre'){return $null}
                if($reads.Count -eq 1){return $rootProcess}
                return $null
            }.GetNewClosure()
            $indeterminate=[bool]$case.Indeterminate
            $adapters.ObserveProcessIdentity={
                param($ProcessId,$ExpectedCreationTimeUtc)
                $observations.Count++
                if($indeterminate){throw 'native creation observation failed'}
                if($stage -ceq 'Final' -and $observations.Count -eq 1){return [pscustomobject][ordered]@{Outcome='Absent';Pid=[int]$ProcessId;CreationTimeUtc=$null}}
                [pscustomobject][ordered]@{Outcome='SameIdentity';Pid=[int]$ProcessId;CreationTimeUtc=[string]$ExpectedCreationTimeUtc}
            }.GetNewClosure()
            $adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
            $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$events.Add("Stop:$($Expected.Pid)");[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
            $result=Invoke-CcodCloseSession -Request (New-CcodEngineRequest -SchemaVersion 2 -Action Close -RestartOrdinary $false -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'Error' $result.outcome "$($case.Name) fails closed"
            Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $result.error.code "$($case.Name) uses the stable close proof error"
            Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,CloseRequested') "$($case.Name) retains the durable CloseRequested checkpoint"
            Assert-CcodTrue (($events -join ',') -cnotmatch 'Closed|WriteStatus|Complete:') "$($case.Name) never writes Closed clears status or archives completion"
            Assert-CcodTrue ($observations.Count -ge 1) "$($case.Name) invokes the strict PID and creation observer"
        }
    }

    Invoke-CcodTest 'stale status accepts PID reuse and one debug replacement only with its new distinct ports' {
        $oldStatus = New-CcodEngineActiveStatus -RuntimeId '2.5.19-old'
        $oldStatus.session.codex.pid = 10664
        $oldStatus.session.codex.creationTimeUtc = '2026-08-26T04:49:22.1551350Z'
        $oldStatus.session.codex.packageFullName = 'OpenAI.Codex_26.820.7780.0_x64__2p2nqsd0c76g0'
        $oldStatus.session.codex.packageVersion = '26.820.7780.0'
        $probe = New-CcodEngineProbe
        $probe.PackageFullName = 'OpenAI.Codex_26.820.9563.0_x64__2p2nqsd0c76g0'
        $probe.PackageVersion = '26.820.9563.0'
        $reuse = New-CcodEngineSnapshot -Pid 10664 -CreationTimeUtc '2026-08-27T07:00:17.0000000Z' -Mode Ordinary
        $debug = New-CcodEngineSnapshot -Pid 13948 -CreationTimeUtc '2026-08-27T07:00:18.0000000Z' -Mode Unrelated -RendererPort 42001 -MainPort 42002
        $debug.CommandLine='"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=42001 --inspect=127.0.0.1:42002'
        foreach($case in @(
            @{Name='PID reuse';Root=$reuse;Observation=[pscustomobject][ordered]@{Outcome='IdentityChanged';Pid=10664;CreationTimeUtc='2026-08-27T07:00:17.0000000Z'};Ports=''},
            @{Name='debug replacement';Root=$debug;Observation=[pscustomobject][ordered]@{Outcome='Absent';Pid=10664;CreationTimeUtc=$null};Ports='42001,42002'}
        )){
            $events=[Collections.Generic.List[string]]::new();$ports=[Collections.Generic.List[int]]::new();$rootValue=$case.Root;$alive=@{([int]$rootValue.Pid)=$rootValue}
            $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $oldStatus) -Probe $probe -Processes @($rootValue) -Events $events
            $adapters.StaticProbe={param($NodeCandidates,$CheckerPath)$probe}.GetNewClosure();$adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
            $adapters.ObserveProcessIdentity={
                param($ProcessId,$ExpectedCreationTimeUtc)
                if(-not $alive.ContainsKey([int]$ProcessId)){return [pscustomobject][ordered]@{Outcome='Absent';Pid=[int]$ProcessId;CreationTimeUtc=$null}}
                $creation=[string]$alive[[int]$ProcessId].CreationTimeUtc
                [pscustomobject][ordered]@{Outcome=if($creation -ceq $ExpectedCreationTimeUtc){'SameIdentity'}else{'IdentityChanged'};Pid=[int]$ProcessId;CreationTimeUtc=$creation}
            }.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
            $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$events.Add("Stop:$($Expected.Pid)");$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$ports.Add([int]$Port);$true}.GetNewClosure()
            $result=Invoke-CcodCloseSession -Request (New-CcodEngineRequest -SchemaVersion 2 -Action Close -RestartOrdinary $false -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'Closed' $result.outcome "$($case.Name) closes the one proven replacement"
            Assert-CcodEqual $case.Ports ($ports -join ',') "$($case.Name) uses only the replacement command-line ports"
        }
    }

    Invoke-CcodTest 'schema-v2 mutations revalidate the lifecycle fence immediately before stop launch bridge status and terminal commit' {
        $targets=@(
            @{Name='stop';Prior='StopRequested';Mutation='StopProcess'},
            @{Name='special launch';Prior='SpecialLaunchRequested';Mutation='StartSpecial'},
            @{Name='bridge injection';Prior='SpecialStarted';Mutation='InvokeNode'},
            @{Name='status write';Prior='Validated';Mutation='WriteStatus'},
            @{Name='transition completion';Prior='WriteVerified';Mutation='Complete:Activated'}
        )
        foreach($target in $targets){
            $source=New-CcodEngineSnapshot;$events=[Collections.Generic.List[string]]::new();$world=[pscustomobject]@{StopCalls=0;StartCalls=0;BridgeCalls=0;StatusWrites=0;Completions=0}
            $adapters=New-CcodEngineAdapters -Processes @($source) -Events $events
            $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$world.StopCalls++;$events.Add('StopProcess');[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
            $baseStart=$adapters.StartSpecial
            $adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$world.StartCalls++;& $baseStart $RendererPort $MainPort $TimeoutMilliseconds}.GetNewClosure()
            $baseNode=$adapters.InvokeNode
            $adapters.InvokeNode={param($NodePath,$Arguments)$world.BridgeCalls++;& $baseNode $NodePath $Arguments}.GetNewClosure()
            $adapters.WriteStatus={param($StateRoot,$Status,$LiveProbe)$world.StatusWrites++;$events.Add('WriteStatus')}.GetNewClosure()
            $adapters.CompleteTransition={param($Path,$LogPath,$TransactionId,$Disposition)$world.Completions++;$events.Add("Complete:$Disposition");[pscustomobject]@{Outcome='Completed'}}.GetNewClosure()
            $prior=[string]$target.Prior
            $adapters.AssertLifecycleFence={
                param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity)
                if($events.Count -gt 0 -and $events[$events.Count-1] -ceq $prior){
                    $exception=[InvalidOperationException]::new('stale lifecycle owner')
                    throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$OwnerIdentity)
                }
                $true
            }.GetNewClosure()
            $request=New-CcodEngineRequest -SchemaVersion 2 -Action Apply -Source $source -ExistingOnly $true
            Assert-CcodThrows { Invoke-CcodApplySession -Request $request -Paths $paths -Adapters $adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
            $actual=@{StopProcess=$world.StopCalls;StartSpecial=$world.StartCalls;InvokeNode=$world.BridgeCalls;WriteStatus=$world.StatusWrites;'Complete:Activated'=$world.Completions}[[string]$target.Mutation]
            Assert-CcodEqual 0 $actual "$($target.Name) does not run after its fence becomes stale"
        }
    }

    Invoke-CcodTest 'durably closes current special or ordinary trees without any ordinary restart' {
        foreach($mode in @('Special','Ordinary')){
            $source=New-CcodEngineSnapshot
            $rootProcess=if($mode -ceq 'Special'){New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002}else{$source}
            $child=New-CcodEngineSnapshot -Pid ($rootProcess.Pid+1) -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -ParentPid $rootProcess.Pid -RendererPort $rootProcess.RendererPort -MainPort $rootProcess.MainPort -IsTopLevel $false
            $status=if($mode -ceq 'Special'){[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}}else{[pscustomobject]@{schemaVersion=1;session=$null}}
            $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$alive=@{}
            $alive[[int]$rootProcess.Pid]=$rootProcess;$alive[[int]$child.Pid]=$child
            $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($rootProcess) -Events $events -Counters $counters
            $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure()
            $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
            $adapters.ObserveProcessIdentity={param($ProcessId,$ExpectedCreationTimeUtc)if($alive.ContainsKey([int]$ProcessId)){[pscustomobject][ordered]@{Outcome='SameIdentity';Pid=[int]$ProcessId;CreationTimeUtc=[string]$ExpectedCreationTimeUtc}}else{[pscustomobject][ordered]@{Outcome='Absent';Pid=[int]$ProcessId;CreationTimeUtc=$null}}}.GetNewClosure()
            $adapters.GetTree={param($Root,$StatusEvidence)@($rootProcess,$child)}.GetNewClosure()
            $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$events.Add("Stop:$($Expected.Pid)");$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
            $result=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'Closed' $result.outcome "$mode close reaches durable Closed"
            Assert-CcodEqual 'Closed' $result.safeState "$mode close reports the explicit closed safe state"
            Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,CloseRequested,Stop:') "$mode commits CloseRequested before the first external stop"
            Assert-CcodEqual "Stop:$($child.Pid),Stop:$($rootProcess.Pid)" ((@($events|Where-Object{$_ -like 'Stop:*'})) -join ',') "$mode close stops child before root"
            Assert-CcodTrue (($events -join ',') -cmatch 'Closed,WriteStatus,Complete:Closed$') "$mode commits Closed then clears status and archives"
            Assert-CcodEqual 0 $counters.OrdinaryStart "$mode close never starts ordinary"
        }
    }

    Invoke-CcodTest 'closes an already empty session and leaves unsafe close evidence durable' {
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -Processes @() -Counters $counters
        $empty=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $empty.outcome 'no current Codex is already closed without inventing a target transaction'

        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $events=[Collections.Generic.List[string]]::new();$unsafeAdapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special) -Events $events -Counters $counters
        $unsafeAdapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $unsafeAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$false}
        $unsafe=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId 'd2cb8a7d-c7b3-4c1c-8a33-f627bb03b927') -Paths $paths -Adapters $unsafeAdapters
        Assert-CcodEqual 'Error' $unsafe.outcome 'open or indeterminate recorded port prevents Closed'
        Assert-CcodTrue (($events -join ',') -cmatch 'CloseRequested') 'unsafe close retains the durable CloseRequested checkpoint'
        Assert-CcodTrue (($events -join ',') -cnotmatch 'Complete:Closed') 'unsafe close is not archived as complete'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'unsafe close never falls into ordinary recovery'
    }

    Invoke-CcodTest 'owns one status-less debug root for close and rejects open ambiguous or unproven roots' {
        $debug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002;$alive=@{100=$debug};$events=[Collections.Generic.List[string]]::new();$stops=[Collections.Generic.List[int]]::new()
        $counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -Processes @($debug) -Events $events -Counters $counts
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        Set-CcodEngineAliveIdentityObserver -Adapters $adapters -Alive $alive
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stops.Add([int]$Expected.Pid);$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure();$adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
        $closed=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $closed.outcome 'one exact status-less debug root is durably close-owned'
        Assert-CcodEqual '100' ($stops -join ',') 'status-less debug root is actually stopped before Closed'
        Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,CloseRequested,Closed') 'debug root close uses durable close checkpoints'

        $openDebug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002;$openAlive=@{100=$openDebug};$openAdapters=New-CcodEngineAdapters -Processes @($openDebug) -Counters $counts
        $openAdapters.ListProcesses={param($StatusEvidence)@($openAlive.Values)}.GetNewClosure();$openAdapters.GetProcess={param($ProcessId,$StatusEvidence)if($openAlive.ContainsKey([int]$ProcessId)){$openAlive[[int]$ProcessId]}else{$null}}.GetNewClosure();$openAdapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        Set-CcodEngineAliveIdentityObserver -Adapters $openAdapters -Alive $openAlive
        $openAdapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$openAlive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure();$openAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$false}
        $open=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId '9c2324b9-07a4-4ad3-9de5-c48dde73c713') -Paths $paths -Adapters $openAdapters
        Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $open.error.code 'open debug ports prevent a false Closed result'

        $second=New-CcodEngineSnapshot -Pid 101 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z' -Mode Unrelated -RendererPort 41003 -MainPort 41004
        $multiStops=[pscustomobject]@{Count=0};$multiAdapters=New-CcodEngineAdapters -Processes @($debug,$second) -Counters $counts;$multiAdapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$multiStops.Count++;throw 'must not stop'}.GetNewClosure()
        $multiple=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId 'bb31007a-54c8-49bb-9302-fab21e2b69e8') -Paths $paths -Adapters $multiAdapters
        Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $multiple.error.code 'multiple current-package roots are never reduced to one close target'
        Assert-CcodEqual 0 $multiStops.Count 'ambiguous roots are not stopped'

        $unpaired=New-CcodEngineSnapshot -Mode Unrelated;$unpaired.RendererPort=41001
        $unproven=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId '4658e91c-30a5-447f-8654-24264f90076e') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($unpaired) -Counters $counts)
        Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $unproven.error.code 'a debug root without a valid distinct port pair is not close-owned'
    }

    Invoke-CcodTest 'never starts ordinary while a status-less debug root remains' {
        $debug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $result=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($debug) -Counters $counts)
        Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code 'normal recovery refuses to coexist with an unowned debug root'
        Assert-CcodEqual 0 $counts.OrdinaryStart 'ordinary is not started beside a debug root'
    }

    Invoke-CcodTest 'suppresses cold missing-root close replay but completes a retained exact live tree' {
        $request=New-CcodEngineRequest -Action Recover -RestartOrdinary $false
        $cold=New-CcodEngineTransition -Stage CloseRequested -WithPorts -WithSpecial -Manual
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -Processes @() -Counters $counters
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
        $coldResult=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $cold -Adapters $adapters
        Assert-CcodEqual 'Error' $coldResult.outcome 'cold replay with already-missing root stays indeterminate even when both ports refuse'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'cold close replay never starts ordinary'

        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $alive=@{201=$special};$events=[Collections.Generic.List[string]]::new();$liveAdapters=New-CcodEngineAdapters -Processes @($special) -Events $events -Counters $counters
        $liveAdapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$liveAdapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
        Set-CcodEngineAliveIdentityObserver -Adapters $liveAdapters -Alive $alive
        $liveAdapters.GetTree={param($Root,$StatusEvidence)@($Root)};$liveAdapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure();$liveAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
        $live=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $cold -Adapters $liveAdapters
        Assert-CcodEqual 'Closed' $live.outcome 'same-execution retained exact tree can prove absence and complete close'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'live close replay still never starts ordinary'

        $closed=New-CcodEngineTransition -Stage Closed -WithPorts -WithSpecial -Manual;$closed.runtimeId='runtime-old';$closed.appAsarSha256=('b'*64)
        $terminalAdapters=New-CcodEngineAdapters -Processes @() -Counters $counters
        $terminalAdapters.StaticProbe={throw 'terminal Closed replay must not require current package or Node evidence'}
        $terminal=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $closed -Adapters $terminalAdapters
        Assert-CcodEqual 'Closed' $terminal.outcome 'Closed replay performs archival only without requiring a live tree again'
    }

    Invoke-CcodTest 'adopts one newly launched ordinary root after an interrupted recovery close' {
        $request=New-CcodEngineRequest -Action Recover -RestartOrdinary $true -TransactionId 'c8c3b2cc-30cc-4cb7-9fb8-55df3a6f4b25'
        $transition=New-CcodEngineTransition -Stage CloseRequested
        $transition.runtimeId='runtime-old'
        $ordinary=New-CcodEngineSnapshot -Pid 302 -CreationTimeUtc '2030-02-03T04:06:04.0000000Z' -Mode Ordinary
        $events=[Collections.Generic.List[string]]::new();$counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($ordinary) -Events $events -Counters $counts
        $adapters.ListProcesses={param($StatusEvidence)@($ordinary)}
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)if([int]$ProcessId -eq [int]$ordinary.Pid){$ordinary}else{$null}}.GetNewClosure()
        $adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={throw 'interrupted recovery must not stop the newly launched ordinary root'}
        $result=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $transition -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'new ordinary root is adopted after the recorded old root disappeared across a runtime upgrade'
        Assert-CcodEqual $ordinary.Pid $result.recovery.pid 'adopted recovery reports the new ordinary PID'
        Assert-CcodTrue (($events -join ',') -cmatch 'Complete:Recovered') 'adopting the new ordinary root archives the interrupted transaction'
        Assert-CcodEqual 0 $counts.OrdinaryStart 'adoption does not start a duplicate ordinary Codex'
    }

    Invoke-CcodTest 'rejects durable close replay from a different current Windows session before stop' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $alive=@{201=$special};$stops=[pscustomobject]@{Count=0};$adapters=New-CcodEngineAdapters -Processes @($special)
        $adapters.CurrentIdentity={[pscustomobject][ordered]@{SessionId='2';UserSid='S-1-5-21-test'}}
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stops.Count++;throw 'must not stop across sessions'}.GetNewClosure()
        $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId 'f14a0fad-6b37-4614-8be2-d38e16b9c030') -Paths $paths -Transition (New-CcodEngineTransition -Stage CloseRequested -WithPorts -WithSpecial -Manual) -Adapters $adapters
        Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code 'close replay requires the current controller session to match the request supervisor'
        Assert-CcodEqual 0 $stops.Count 'cross-session close replay performs no process action'
    }

    Invoke-CcodTest 'rejects CloseRequested replay when any second current-package root remains' {
        foreach($journalMode in @('Ordinary','Special')){
            foreach($extraMode in @('Ordinary','Unrelated')){
                $rootProcess=if($journalMode -ceq 'Special'){
                    New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
                }else{New-CcodEngineSnapshot}
                $extra=if($extraMode -ceq 'Unrelated'){
                    New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:09.0000000Z' -Mode Unrelated -RendererPort 42001 -MainPort 42002
                }else{New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:09.0000000Z'}
                $transition=if($journalMode -ceq 'Special'){
                    New-CcodEngineTransition -Stage CloseRequested -WithPorts -WithSpecial -Manual
                }else{New-CcodEngineTransition -Stage CloseRequested}
                $alive=@{};$alive[[int]$rootProcess.Pid]=$rootProcess;$alive[[int]$extra.Pid]=$extra
                $events=[Collections.Generic.List[string]]::new();$stops=[pscustomobject]@{Count=0}
                $adapters=New-CcodEngineAdapters -Processes @($rootProcess,$extra) -Events $events
                $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure()
                $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
                $adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
                $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stops.Count++;$alive.Remove([int]$Expected.Pid)|Out-Null;[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
                $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
                $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Transition $transition -Adapters $adapters
                Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $result.error.code "$journalMode journal plus $extraMode root fails closed"
                Assert-CcodEqual 0 $stops.Count "$journalMode journal plus $extraMode root performs no stop"
                Assert-CcodTrue (($events -join ',') -cnotmatch 'Closed|Complete:') "$journalMode journal plus $extraMode root performs no stage or completion write"
            }
        }
    }

    Invoke-CcodTest 'finishes an older recovery before creating a separate DoNotRestart close transaction' {
        $old=New-CcodEngineTransition -Stage Recovered -WithRecovery;$ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z';$alive=@{301=$ordinary}
        $withOld=New-CcodEngineState -ActiveTransaction $old;$withoutOld=New-CcodEngineState;$reads=[pscustomobject]@{Count=0};$events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -State $withOld -Processes @($ordinary) -Events $events -Counters $counters
        $adapters.ReadState={param($StateRoot,$SuppressionKey)$reads.Count++;if($reads.Count -le 2){$withOld}else{$withoutOld}}.GetNewClosure()
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        Set-CcodEngineAliveIdentityObserver -Adapters $adapters -Alive $alive
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $request=New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId '16df4637-47f5-4758-89a4-f04c7e7375cf'
        $result=Invoke-CcodRecoverSession -Request $request -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $result.outcome 'old recovery is safely finalized and its ordinary result is then closed'
        Assert-CcodEqual $request.transactionId $result.transactionId 'separate close keeps the new request correlation ID'
        Assert-CcodTrue (($events -join ',') -cmatch 'Complete:Recovered,StaticProbe,IntentWritten,CloseRequested') 'older transaction archives before the independent close intent'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'DoNotRestart never starts another ordinary after CloseRequested'
    }

    Invoke-CcodTest 'repairs only the recorded renderer endpoint and never supplies main Inspector arguments' {
        $status=New-CcodEngineActiveStatus -RuntimeId 'runtime-old'
        $broken=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $captured=[pscustomobject]@{Arguments=$null;StatusRuntime=$null;LiveRuntime=$null};$repairOrder=[Collections.Generic.List[string]]::new();$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($broken)
        $rendererProof=[ordered]@{ok=$true;protocolVersion=1;renderer=[ordered]@{targetUrl='app://-/index.html';currentDocument=[ordered]@{installed=$true};newDocumentScriptInstalled=$true;probe=[ordered]@{proof=$true;targetGate='782640499'}}}
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$repairOrder.Add("Wait:${Port}:${TimeoutMilliseconds}");$true}.GetNewClosure()
        $adapters.InvokeNode={param($NodePath,$Arguments)$repairOrder.Add('InvokeNode');$captured.Arguments=@($Arguments);[pscustomobject][ordered]@{ExitCode=0;Stdout=($rendererProof|ConvertTo-Json -Depth 16 -Compress);Stderr=''}}.GetNewClosure()
        $adapters.WriteStatus={param($StateRoot,$Status,$LiveProbe)$captured.StatusRuntime=$Status.session.runtimeId;$captured.LiveRuntime=$LiveProbe.runtimeId}.GetNewClosure()
        $restartRequest=New-CcodEngineRequest -Action RepairRenderer -SupervisorPid 22 -SupervisorCreationTimeUtc '2030-02-03T05:00:00.0000000Z'
        $result=Invoke-CcodRepairRenderer -Request $restartRequest -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'NoAction' $result.outcome 'successful renderer repair needs no process normalization'
        Assert-CcodEqual 'SpecialValidated' $result.safeState 'renderer-only proof restores validated special state'
        Assert-CcodEqual "$($paths.OrchestratorPath),--mode,renderer,--renderer-port,41001,--timeout-ms,30000" ($captured.Arguments -join ',') 'renderer repair passes renderer mode, its recorded port, and the request timeout'
        Assert-CcodTrue (($captured.Arguments -join ',') -cnotmatch 'main') 'renderer repair never passes a main connector argument'
        Assert-CcodEqual 'Wait:41002:30000,InvokeNode' ($repairOrder -join ',') 'explicit main refusal is proven before renderer-only child invocation'
        Assert-CcodEqual 'runtime-1' $captured.StatusRuntime 'post-upgrade repair migrates status to the current runtime'
        Assert-CcodEqual 'runtime-1' $captured.LiveRuntime 'post-upgrade repair proves status with the current runtime'
        Assert-CcodEqual 22 $restartRequest.supervisorIdentity.pid 'repair regression uses a genuinely restarted supervisor identity'

        $missing=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer -TransactionId '36cafc98-f225-43bd-ae33-b9a608ac68da') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @())
        Assert-CcodEqual 'Error' $missing.outcome 'renderer repair fails closed without exact persisted special identity'
    }

    Invoke-CcodTest 'normalizes once without renderer or Active writes when repair main refusal is unproven' {
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002;$alive=@{201=$special}
        $counts=[pscustomobject]@{Wait=0;Node=0;ActiveWrites=0;RecoveryStages=0;SpecialStart=0;OrdinaryStart=0;Recover=0}
        $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special) -Counters $counts
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$counts.Wait++;return ($counts.Wait -gt 1)}.GetNewClosure()
        $adapters.InvokeNode={param($NodePath,$Arguments)$counts.Node++;New-CcodFullBridgeInvocation}.GetNewClosure()
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        Set-CcodEngineAliveIdentityObserver -Adapters $adapters -Alive $alive
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $baseSet=$adapters.SetTransition;$adapters.SetTransition={param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)if($NewStage -ceq 'RecoveryLaunchRequested'){$counts.RecoveryStages++};& $baseSet $Path $TransactionId $ExpectedStage $NewStage $SpecialIdentity $RecoveryIdentity $RendererPort $MainPort}.GetNewClosure()
        $adapters.WriteStatus={param($StateRoot,$Status,$LiveProbe)if($null -ne $LiveProbe){$counts.ActiveWrites++}}
        $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'unproven main refusal enters ordinary normalization'
        Assert-CcodEqual 1 $counts.RecoveryStages 'repair failure enters recovery exactly once'
        Assert-CcodEqual 0 $counts.Node 'renderer child is never invoked while main refusal is unproven'
        Assert-CcodEqual 0 $counts.ActiveWrites 'failed repair never writes Active status evidence'
    }

    Invoke-CcodTest 'rejects every mismatched live repair identity dimension before renderer activity' {
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        foreach($field in @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','RendererPort','MainPort')){
            $candidate=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
            switch($field){'Pid'{$candidate.Pid=202};'CreationTimeUtc'{$candidate.CreationTimeUtc='2030-02-03T04:05:08.0000000Z'};'SessionId'{$candidate.SessionId=2};'UserSid'{$candidate.UserSid='S-1-5-21-other'};'Path'{$candidate.Path='C:\Other\ChatGPT.exe'};'PackageFamilyName'{$candidate.PackageFamilyName='Other.Family'};'RendererPort'{$candidate.RendererPort=42001};'MainPort'{$candidate.MainPort=42002}}
            $counts=[pscustomobject]@{Node=0;Wait=0;SpecialStart=0;OrdinaryStart=0;Recover=0};$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($candidate) -Counters $counts
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$counts.Wait++;$true}.GetNewClosure();$adapters.InvokeNode={param($NodePath,$Arguments)$counts.Node++;New-CcodFullBridgeInvocation}.GetNewClosure()
            $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'CCOD_SOURCE_CHANGED' $result.error.code "$field mismatch fails the repair identity gate"
            Assert-CcodEqual 0 $counts.Wait "$field mismatch performs no port observation"
            Assert-CcodEqual 0 $counts.Node "$field mismatch performs no renderer activity"
        }
    }

    Invoke-CcodTest 'normal Recover keeps ordinary or starts exactly one ordinary when Codex is closed' {
        $ordinary=New-CcodEngineSnapshot;$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $kept=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($ordinary) -Counters $counters)
        Assert-CcodEqual 'NoAction' $kept.outcome 'an existing exact ordinary root is already normalized'
        Assert-CcodEqual 'OrdinaryRunning' $kept.safeState 'existing ordinary root is reported without mutation'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'existing ordinary root is never duplicated'

        $clock=[pscustomobject]@{Delayed=0};$adapters=New-CcodEngineAdapters -Processes @() -Counters $counters;$adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
        $started=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -TransactionId 'fc711735-3020-439d-b95f-e820866cfb45') -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Recovered' $started.outcome 'closed Codex is returned to an ordinary session'
        Assert-CcodEqual 5000 $clock.Delayed 'normal Recover observes absence for fake five seconds before launch'
        Assert-CcodEqual 1 $counters.OrdinaryStart 'normal Recover launches ordinary exactly once'
    }

    Invoke-CcodTest 'Recover clears a committed stale recovery before cross-runtime replay' {
        $transaction = New-CcodEngineTransition -Stage Recovered -WithPorts -WithSpecial -WithRecovery -TransactionId 'aa891d93-27b2-4dc4-8f78-1714f7a3b65c'
        $transaction.runtimeId = 'runtime-old'
        $state = New-CcodEngineState -ActiveTransaction $transaction
        $ordinary = New-CcodEngineSnapshot
        $clearCalls = [Collections.Generic.List[string]]::new()
        $adapters = New-CcodEngineAdapters -State $state -Processes @($ordinary)
        $adapters.ClearCommittedTransition = {
            param($Path,$LogPath,$TransactionId,$Disposition)
            $clearCalls.Add("$TransactionId|$Disposition")
            $state.Transition.activeTransaction = $null
            [pscustomobject][ordered]@{ Outcome='Completed'; ArchiveState='PreviouslyWritten'; ArchiveErrorId=$null }
        }.GetNewClosure()

        $result = Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RuntimeId 'runtime-1' -TransactionId '96ab45cf-5c63-4c0e-a958-76d5bc514813') -Paths $paths -Adapters $adapters
        Assert-CcodEqual "$($transaction.transactionId)|Recovered" ($clearCalls -join ',') 'recovery clears only the matching committed transaction'
        Assert-CcodEqual 'NoAction' $result.outcome 'recovery continues after clearing the stale committed transaction'
        Assert-CcodEqual 'OrdinaryRunning' $result.safeState 'recovery re-evaluates the current ordinary session'
    }

    Invoke-CcodTest 'renderer repair failure normalizes once and suppresses the failed runtime' {
        $status=New-CcodEngineActiveStatus -RuntimeId 'runtime-old'
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002;$alive=@{201=$special}
        $existingVerified=New-CcodEngineVerifiedPackages -RuntimeId 'runtime-old'
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status -VerifiedPackages $existingVerified) -Processes @($special) -Counters $counters
        $writtenVerified=[pscustomobject]@{Value=$null}
        $adapters.InvokeNode={param($NodePath,$Arguments)[pscustomobject][ordered]@{ExitCode=0;Stdout='{}';Stderr=''}}
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        Set-CcodEngineAliveIdentityObserver -Adapters $adapters -Alive $alive
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $adapters.ReadVerified={param($StateRoot)$existingVerified}.GetNewClosure()
        $adapters.WriteVerified={param($StateRoot,$Verified)$writtenVerified.Value=$Verified}.GetNewClosure()
        $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'renderer proof failure returns a proven ordinary recovery'
        Assert-CcodEqual 1 $counters.OrdinaryStart 'renderer repair recovery launches ordinary at most once'
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.suppressionKey)) 'renderer repair failure returns suppression evidence'
        Assert-CcodTrue ($result.recovery.suppressionKey.EndsWith('|runtime-1',[StringComparison]::Ordinal)) 'failed post-upgrade repair suppresses the current request runtime'
        $oldKey='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-old';$currentKey='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-1'
        Assert-CcodEqual 'Succeeded' $writtenVerified.Value.packages.PSObject.Properties[$oldKey].Value.dynamicOutcome 'old successful provenance remains intact'
        Assert-CcodEqual 'Failed' $writtenVerified.Value.packages.PSObject.Properties[$currentKey].Value.dynamicOutcome 'failed work is recorded only for the current runtime'
    }

    Invoke-CcodTest 'rejects renderer repair provenance before current-runtime work or side effects' {
        $status=New-CcodEngineActiveStatus -RuntimeId 'runtime-old'
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $empty=[pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{}}
        $counts=[pscustomobject]@{Static=0;Node=0;Wait=0;Transition=0;Write=0;SpecialStart=0;OrdinaryStart=0;Recover=0}
        $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status -VerifiedPackages $empty) -Processes @($special) -Counters $counts
        $adapters.StaticProbe={param($Candidates,$Checker)$counts.Static++;throw 'must not probe current package before old provenance'}.GetNewClosure()
        $adapters.InvokeNode={param($Node,$Arguments)$counts.Node++;throw 'must not invoke renderer'}.GetNewClosure()
        $adapters.WaitPortClosed={param($Port,$Timeout)$counts.Wait++;throw 'must not inspect port'}.GetNewClosure()
        foreach($name in @('NewTransition','SetTransition','CompleteTransition','WriteStatus','WriteVerified','StopProcess','StartOrdinary')){$adapters[$name]={$counts.Transition++;throw 'must not mutate'}.GetNewClosure()}
        $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Error' $result.outcome 'missing exact old provenance blocks repair'
        Assert-CcodTrue (@('CCOD_STATE_BLOCKED','CCOD_VERIFIED_PACKAGES_INVALID') -ccontains $result.error.code) 'pre-attempt provenance uses an existing stable classification'
        Assert-CcodEqual 0 ($counts.Static+$counts.Node+$counts.Wait+$counts.Transition) 'pre-attempt provenance failure has no current-runtime or mutating side effect'
    }

    Invoke-CcodTest 'production adapter declarations call upstream APIs and contain no empty process placeholder' {
        $moduleText=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'src\persistence\modules\SessionEngine.psm1'))
        foreach($command in @('Invoke-CcodStaticProbe','Get-CcodProcessSnapshot','Test-CcodProcessMatch','Stop-CcodProcessIfMatch','Get-CcodVerifiedProcessTree','Get-CcodTransactionProcessResult','Get-CcodAvailableLoopbackPort','Start-CcodProcess','Wait-CcodPortClosed','Read-CcodState','Write-CcodStatus','Write-CcodVerifiedPackages','New-CcodTransition','Set-CcodTransitionStage','Complete-CcodTransition')){Assert-CcodTrue ($moduleText -cmatch [regex]::Escape($command)) "production adapters wire $command"}
        Assert-CcodTrue ($moduleText -cnotmatch 'ListProcesses=\{\s*param\([^)]*\)\s*@\(\)\s*\}') 'production process enumeration is not an always-empty placeholder'
        $inspectionStart=$moduleText.IndexOf('function Merge-CcodInspectionAdapters',[StringComparison]::Ordinal)
        $inspectionEnd=$moduleText.IndexOf('function Assert-CcodInspectionState',[StringComparison]::Ordinal)
        Assert-CcodTrue ($inspectionStart -ge 0 -and $inspectionEnd -gt $inspectionStart) 'production inspection adapter block is present'
        $inspectionText=$moduleText.Substring($inspectionStart,$inspectionEnd-$inspectionStart)
        foreach($name in @('ReadInspectionState','GetPackageIdentity','ResolveNodeCandidate','GetPersistedSpecialIdentity','InvokeNode','CurrentIdentity','ListProcesses','ProcessMatch')){
            Assert-CcodEqual 1 ([regex]::Matches($inspectionText,"(?m)^\s{8}$name=\{").Count) "inspection declares $name exactly once"
        }
        foreach($reader in @('Read-CcodSettings','Read-CcodStatus','Read-CcodVerifiedPackages')){Assert-CcodTrue ($inspectionText -cmatch [regex]::Escape($reader)) "strict inspection composition calls $reader"}
        Assert-CcodTrue ($inspectionText -cnotmatch '(?m)^\s{8}(?:ReadState|StaticProbe|WriteLog|WriteStatus|WriteVerified|NewTransition|SetTransition|CompleteTransition|StopProcess|StartSpecial|StartOrdinary|WaitPortClosed)=\{') 'inspection receives no aggregate reader or mutating adapter'
        Assert-CcodTrue ($inspectionText -cnotmatch '\bRead-CcodState\b|\bInvoke-CcodStaticProbe\b|\bWrite-Ccod') 'inspection adapter block never quarantines hashes or writes state'
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
