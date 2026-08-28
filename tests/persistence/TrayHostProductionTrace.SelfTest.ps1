param(
    [string]$AssemblyPath,
    [string]$CurrentTracePath,
    [string]$StaleTracePath,
    [string]$ProductionExePath
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if([string]::IsNullOrEmpty($AssemblyPath)-and[string]::IsNullOrEmpty($CurrentTracePath)-and[string]::IsNullOrEmpty($StaleTracePath)-and[string]::IsNullOrEmpty($ProductionExePath)){
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot 'tests\trayhost\Invoke-TrayHostSelfTest.ps1') -ProductionTraceOnly
    exit $LASTEXITCODE
}
foreach($path in @($AssemblyPath,$CurrentTracePath,$StaleTracePath,$ProductionExePath)){if([string]::IsNullOrEmpty($path)-or-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'CCOD_TRAYHOST_PRODUCTION_TRACE_INPUT_INVALID'}}

. (Join-Path $PSScriptRoot 'TestSupport.ps1')
[Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))|Out-Null
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TrayHostClient.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $repositoryRoot 'src\persistence\Supervisor.ps1') -ReadyToken ('a'*64)

function New-CcodProductionTraceContext {
    param($Client)
    $enabled=[pscustomobject][ordered]@{RepairEnabled=$false;LanguageEnabled=$false;OpenLogsEnabled=$true;AboutEnabled=$false;ExitEnabled=$false;Busy=$false}
    $acknowledged=[ordered]@{};$acknowledged['1']=$enabled
    $queue=[Collections.Generic.Queue[object]]::new()
    $context=[pscustomobject][ordered]@{
        Client=$Client;CommandQueue=$queue;CurrentRevision=[UInt64]1;LastAcknowledgedRevision=[UInt64]1
        PublishedPresentations=[ordered]@{};AcknowledgedPresentations=$acknowledged;Exited=$false;LastError=$null
    }
    return [pscustomobject][ordered]@{Context=$context;Enabled=$enabled}
}

function New-CcodProductionTraceHostState {
    param($Context,$Enabled)
    return [pscustomobject][ordered]@{
        Tray=$Context;LastAcknowledgedPresentation=$Enabled;TrayActionIds=[ordered]@{}
        WorkerSlot=$null;LifecycleWorkerSlot=$null;LifecycleRequest=$null;Journal=$null
        State=[pscustomobject][ordered]@{AutomationEnabled=$true;Settings=[pscustomobject]@{candidateCompatibleOptIn=$false};VerifiedPackages=[pscustomobject][ordered]@{};Damage=$null}
        Identity=[pscustomobject][ordered]@{UserSid='S-1-5-21-111-222-333-1001';SessionId=[int]1}
        Layout=[pscustomobject][ordered]@{RuntimeId='trace-runtime';LogDirectory='C:\Trace\Logs'}
        PackageFullName=$null;AppAsarSha256=$null;Classification=$null;Ordinary=[object[]]@();Special=[object[]]@()
        AttemptKeys=[ordered]@{};RecoveryIgnoreKeys=[ordered]@{};SuppressionKeys=[ordered]@{}
        RuntimeCleanupCodes=[Collections.Generic.List[string]]::new()
    }
}

function Wait-CcodProductionTraceWitness {
    param([string]$Path,$Context,[scriptblock]$Condition)
    $deadline=[DateTime]::UtcNow.AddSeconds(4)
    while([DateTime]::UtcNow-lt$deadline){
        Receive-CcodTrayHostEvents -Context $Context
        $lines=if(Test-Path -LiteralPath $Path -PathType Leaf){@(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)}else{@()}
        if(& $Condition $lines){return @($lines)}
        [void]$Context.Client.WaitForActivity([TimeSpan]::FromMilliseconds(25))
    }
    throw 'CCOD_TRAYHOST_PRODUCTION_TRACE_WITNESS_TIMEOUT'
}

function Invoke-CcodProductionTraceCase {
    param([string]$TracePath,[bool]$Stale)
    $client=[TrayHostProductionTraceFixture]::Start($TracePath)
    try{
        $parentProcess=[Diagnostics.Process]::GetCurrentProcess()
        try{Assert-CcodTrue ($client.Receipt.HostPid-gt0-and$client.Receipt.HostPid-ne$parentProcess.Id) 'normal parent start launches a distinct child process'}finally{$parentProcess.Dispose()}
        $childProcess=[Diagnostics.Process]::GetProcessById($client.Receipt.HostPid)
        try{Assert-CcodTrue ([string]::Equals([IO.Path]::GetFullPath($TracePath),[IO.Path]::GetFullPath($childProcess.MainModule.FileName),[StringComparison]::OrdinalIgnoreCase)) 'normal parent start launches the requested temporary trace executable'}finally{$childProcess.Dispose()}
        Assert-CcodEqual 'trace-runtime' $client.Receipt.RuntimeId 'real child handshake preserves the opaque runtime identity'
        $fixture=New-CcodProductionTraceContext $client;$context=$fixture.Context
        $hostState=New-CcodProductionTraceHostState $context $fixture.Enabled
        $opened=[Collections.Generic.List[string]]::new();$supervisorReceipts=[Collections.Generic.List[object]]::new()
        $adapters=@{
            GetUtcNow={ [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime() }
            OpenLogs={param($Path)[void]$opened.Add([string]$Path)}.GetNewClosure()
            WriteLog={param($Record)[void]$supervisorReceipts.Add($Record)}.GetNewClosure()
            SendTrayActionResult={param($Tray,$ActionId,$Revision,$Status,$ErrorCode,$TransactionId)[bool](Send-CcodTrayHostActionResult -Context $context -ActionId $ActionId -Revision ([UInt64]$Revision) -Status $Status -ErrorCode $ErrorCode -TransactionId $TransactionId)}.GetNewClosure()
        }

        $deadline=[DateTime]::UtcNow.AddSeconds(4)
        while($context.CommandQueue.Count-eq0-and[DateTime]::UtcNow-lt$deadline){[void]$client.WaitForActivity([TimeSpan]::FromMilliseconds(25));Receive-CcodTrayHostEvents -Context $context}
        Assert-CcodEqual 1 $context.CommandQueue.Count 'real TrayHostClient receives one authenticated child-session action'
        $action=$context.CommandQueue.Dequeue()
        Assert-CcodTrue ($action.ActionId-ne[guid]::Empty) 'production trace preserves a nonempty action id'
        Assert-CcodEqual 'OpenLogs' $action.Command 'production trace preserves OpenLogs through native/session/wire/client'
        $expectedRevision=if($Stale){[UInt64]8}else{[UInt64]1}
        Assert-CcodEqual $expectedRevision $action.Revision 'production trace preserves the exact action revision'

        $results=@(Invoke-CcodSupervisorCommand $hostState $adapters $action)
        Assert-CcodEqual 1 $results.Count 'Supervisor produces one terminal result'
        $expectedStatus=if($Stale){'Rejected'}else{'Completed'}
        $expectedCode=if($Stale){'CCOD_TRAY_ACTION_STALE'}else{$null}
        Assert-CcodEqual $expectedStatus $results[0].Status 'Supervisor makes the expected revision-bound decision'
        if($Stale){Assert-CcodEqual $expectedCode $results[0].ErrorCode 'Supervisor preserves the expected terminal code'}else{Assert-CcodTrue ([string]::IsNullOrEmpty($results[0].ErrorCode)) 'current completion carries no terminal error code'}
        Assert-CcodEqual $true $results[0].Delivered 'Supervisor sends the terminal result through real TrayHostClient'
        Assert-CcodEqual $(if($Stale){0}else{1}) $opened.Count 'OpenLogs side effect occurs only for the current action'
        Assert-CcodEqual 1 $supervisorReceipts.Count 'Supervisor records exactly one terminal decision'

        $witnessPath=[TrayHostProductionTraceFixture]::GetWitnessPath($TracePath)
        $condition=if($Stale){{param($Items)@($Items|Where-Object{$_-like'dialog *'}).Count-eq1}}else{{param($Items)@($Items|Where-Object{$_-eq'publication accepted=true'}).Count-eq1}}
        $lines=Wait-CcodProductionTraceWitness $witnessPath $context $condition
        $receipt="receipt command=OpenLogs revision=$expectedRevision status=$expectedStatus code=$(if($Stale){'CCOD_TRAY_ACTION_STALE'}else{'CCOD_TRAY_ACTION_COMPLETED'})"
        Assert-CcodEqual 1 @($lines|Where-Object{$_-like'receipt *'}).Count 'child async sink writes exactly one terminal receipt'
        Assert-CcodTrue ($lines-ccontains$receipt) 'child receipt is exact and sanitized'
        Assert-CcodEqual 1 @($lines|Where-Object{$_-eq'publication accepted=true'}).Count 'durable receipt callback publishes exactly once'
        if($Stale){
            Assert-CcodTrue ($lines-ccontains'fixture command=OpenLogs revision=8') 'stale action comes from the test-only authenticated fixture'
            $tokenPosts=@($lines|Where-Object{$_-cmatch'^post message=32771 token=[1-9][0-9]*$'})
            Assert-CcodTrue ($tokenPosts.Count-ge1) 'stale durable callback uses nonzero tokened WmApp+3 work'
            $dialog='dialog caption=trace-0 text=trace-15'
            Assert-CcodEqual 1 @($lines|Where-Object{$_-like'dialog *'}).Count 'stale result displays one generic dialog'
            Assert-CcodTrue ($lines-ccontains$dialog) 'stale dialog contains only acknowledged generic UI text'
            Assert-CcodTrue ([Array]::IndexOf([object[]]$lines,$receipt)-lt[Array]::IndexOf([object[]]$lines,$dialog)) 'generic dialog occurs only after durable receipt success'
            Assert-CcodTrue ([Array]::IndexOf([object[]]$lines,$tokenPosts[0])-lt[Array]::IndexOf([object[]]$lines,$dialog)) 'generic dialog is drained through tokened receipt work'
            Assert-CcodTrue ($dialog-cnotmatch'CCOD_|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') 'generic dialog leaks no internal code or correlation id'
        }else{
            Assert-CcodTrue ($lines-ccontains'native-menu command=OpenLogs') 'current action originates from real TrayWindow.HandleContextMenu'
            Assert-CcodTrue ($lines-ccontains'native command=OpenLogs revision=1') 'current native selection retains the displayed revision'
            Assert-CcodEqual 0 @($lines|Where-Object{$_-like'dialog *'}).Count 'current completion displays no generic dialog'
        }

        Receive-CcodTrayHostEvents -Context $context
        Assert-CcodEqual 0 $context.CommandQueue.Count 'production trace emits no duplicate action'
        Assert-CcodTrue ([string]::IsNullOrEmpty($context.LastError)) 'production trace emits no remote fault'
        Assert-CcodTrue $client.BeginShutdown([ShutdownReason]::SupervisorExit,[UInt64]1) 'parent requests normal authenticated shutdown'
        Assert-CcodTrue $client.WaitForStopped([TimeSpan]::FromSeconds(4)) 'child session returns an authenticated shutdown acknowledgement'
        Receive-CcodTrayHostEvents -Context $context
        Assert-CcodEqual $true $context.Exited 'TrayHostClient observes the normal child exit'
        Assert-CcodTrue ([string]::IsNullOrEmpty($context.LastError)) 'normal child shutdown has no fault'
        Assert-CcodEqual 0 $context.CommandQueue.Count 'normal child shutdown adds no extra action'
    }finally{$client.Dispose()}
}

& $ProductionExePath '--production-trace-test-selector'
Assert-CcodEqual 2 $LASTEXITCODE 'shipped Program.Main rejects the temporary trace selector'
Invoke-CcodProductionTraceCase $CurrentTracePath $false
Invoke-CcodProductionTraceCase $StaleTracePath $true
Write-Host 'TrayHost production child-session trace passed: 2'
