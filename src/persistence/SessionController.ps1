[CmdletBinding(DefaultParameterSetName='Manual')]
param(
    [Parameter(ParameterSetName='Supervisor')]
    [string]$RequestPath,
    [Parameter(ParameterSetName='Supervisor')]
    [string]$ResultPath,
    [Parameter(ParameterSetName='Manual')]
    [ValidateSet('Inspect','Close','Apply','RepairRenderer')]
    [string]$Action,
    [Parameter(ParameterSetName='Manual')]
    [bool]$ExistingOnly=$true,
    [Parameter(ParameterSetName='Manual')]
    [Nullable[int]]$RendererPort=$null,
    [Parameter(ParameterSetName='Manual')]
    [Nullable[int]]$MainPort=$null,
    [Parameter(ParameterSetName='Manual')]
    [ValidateRange(500,120000)][int]$TimeoutMilliseconds=30000,
    [Parameter(ParameterSetName='Manual')]
    [bool]$RestartOrdinary=$true
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'

$controllerModuleRoot=Join-Path $PSScriptRoot 'modules'
$script:CcodControllerScriptPath=[IO.Path]::GetFullPath($PSCommandPath)
Import-Module (Join-Path $controllerModuleRoot 'SessionEngine.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'RuntimeManifest.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'LifecycleEpoch.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'TransitionJournal.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'KernelObjects.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'PersistenceIO.psm1') -Force -Global
Import-Module (Join-Path $controllerModuleRoot 'ProcessControl.psm1') -Force -Global

function Test-CcodControllerCanonicalGuid([object]$Value){
    if($Value -isnot [string]){return $false}
    $parsed=[guid]::Empty
    return [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function New-CcodControllerErrorResult {
    param($Request,[string]$Code,[string]$Stage,[string]$Message)
    $action=$null;$transactionId=$null
    if($null -ne $Request -and $null -ne $Request.PSObject.Properties['action'] -and $Request.action -is [string]){
        if(($null -ne $Request.PSObject.Properties['schemaVersion'] -and $Request.schemaVersion -eq 2 -and @('Inspect','Close','Apply','RepairRenderer') -ccontains $Request.action) -or
           ($null -ne $Request.PSObject.Properties['schemaVersion'] -and $Request.schemaVersion -eq 1 -and $Request.action -ceq 'Recover')){$action=$Request.action}
    }
    if($null -ne $Request -and $null -ne $Request.PSObject.Properties['transactionId'] -and (Test-CcodControllerCanonicalGuid $Request.transactionId)){$transactionId=$Request.transactionId}
    [pscustomobject][ordered]@{schemaVersion=1;action=$action;ok=$false;outcome='Error';safeState='Error';stage=$Stage;transactionId=$transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=[pscustomobject][ordered]@{code=$Code;stage=$Stage;message='The session controller failed safely. See the session log for details.'};logFile=$null}
}

function Write-CcodControllerDiagnostic {
    param($Result,$Request,$Paths,[hashtable]$Adapter)
    if($null -eq $Result -or $null -eq $Paths -or $null -eq $Adapter -or $null -eq $Adapter.WriteLog){return $false}
    try{
        $now=& $Adapter.UtcNow;if($now -isnot [DateTime]){return $false}
        $record=[pscustomobject][ordered]@{
            schemaVersion=1
            timestampUtc=$now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            action=$Result.action
            transactionId=$Result.transactionId
            stage=$Result.stage
            code=$Result.error.code
        }
        & $Adapter.WriteLog $Paths.SessionLogPath ($record|ConvertTo-Json -Depth 4 -Compress)|Out-Null
        $Result.logFile=$Paths.SessionLogPath
        return $true
    }catch{return $false}
}

function Write-CcodControllerAbandonedWarning {
    param($Request,$Paths,[hashtable]$Adapter)
    if($null -eq $Request -or $null -eq $Paths -or $null -eq $Adapter -or $null -eq $Adapter.WriteLog){return $false}
    try{
        $now=& $Adapter.UtcNow;if($now -isnot [DateTime]){return $false}
        $record=[pscustomobject][ordered]@{
            schemaVersion=1
            timestampUtc=$now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            action=$Request.action
            transactionId=$Request.transactionId
            stage='LeaseAcquire'
            code='CCOD_TRANSITION_ABANDONED'
        }
        & $Adapter.WriteLog $Paths.SessionLogPath ($record|ConvertTo-Json -Depth 4 -Compress)|Out-Null;return $true
    }catch{return $false}
}

function Assert-CcodControllerEngineResult {
    param($Result,$Request)
    $expected=@('schemaVersion','action','ok','outcome','safeState','stage','transactionId','package','source','special','probes','recovery','error','logFile')
    if($null -eq $Result -or $Result -isnot [pscustomobject] -or @($Result.PSObject.Properties).Count -ne $expected.Count){throw 'engine result is not the exact 14-field object'}
    foreach($name in $expected){if($null -eq $Result.PSObject.Properties[$name]){throw 'engine result is not the exact 14-field object'}}
    if($Result.schemaVersion -ne 1 -or $Result.action -cne $Request.action -or $Result.transactionId -cne $Request.transactionId -or $Result.ok -isnot [bool] -or $Result.outcome -isnot [string]){throw 'engine result correlation or scalar fields are invalid'}
}

function Get-CcodControllerProcessProvenance {
    param([int]$ProcessId)
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById($ProcessId)
        $firstCreated=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $sessionId=[int]$process.SessionId
        $cim=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if($null -eq $cim -or [int]$cim.ProcessId -ne $ProcessId){return $null}
        $owner=Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop
        $process.Refresh();$secondCreated=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        if($firstCreated -cne $secondCreated -or [int]$process.SessionId -ne $sessionId -or $owner.ReturnValue -ne 0 -or $owner.Sid -isnot [string]){return $null}
        [pscustomobject][ordered]@{
            Pid=$ProcessId;CreationTimeUtc=$firstCreated;SessionId=$sessionId;UserSid=[string]$owner.Sid
            Path=[string]$cim.ExecutablePath;CommandLine=[string]$cim.CommandLine;ParentPid=[int]$cim.ParentProcessId
        }
    }catch{return $null}finally{if($null -ne $process){$process.Dispose()}}
}

function ConvertFrom-CcodControllerProcessCommandLine {
    param([string]$CommandLine)
    try{
        $module=Get-Module ProcessControl -ErrorAction Stop
        return @(& $module {param($Value)Initialize-CcodProcessNativeApi;[Ccod.Persistence.Native.CommandLineV1]::Parse($Value)} $CommandLine)
    }catch{return @()}
}

function Test-CcodControllerLegacySafeRoot {
    param([string]$Path)
    try{
        $canonical=[IO.Path]::GetFullPath($Path)
        if($canonical -cne $Path -or -not [IO.Directory]::Exists($canonical)){return $false}
        $cursor=$canonical
        while(-not [string]::IsNullOrWhiteSpace($cursor)){
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $false}
            $parent=Split-Path -Parent $cursor;if($parent -ceq $cursor){break};$cursor=$parent
        }
        return $true
    }catch{return $false}
}

function Get-CcodControllerAdapters($Adapters){
    $defaults=@{
        GetIdentity={
            $identity=$null;$process=$null
            try{
                $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess()
                [pscustomobject][ordered]@{UserSid=$identity.User.Value;SessionId=[int]$process.SessionId}
            }finally{if($null -ne $process){$process.Dispose()};if($null -ne $identity){$identity.Dispose()}}
        }
        GetSupervisorProcess={param($ProcessId)
            $process=$null
            try{
                $process=[Diagnostics.Process]::GetProcessById([int]$ProcessId)
                $created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
                [pscustomobject][ordered]@{Pid=[int]$process.Id;CreationTimeUtc=$created;SessionId=[int]$process.SessionId}
            }catch{return $null}finally{if($null -ne $process){$process.Dispose()}}
        }
        GetCurrentProcessId={[int]$PID}
        GetProcessProvenance={param($ProcessId)Get-CcodControllerProcessProvenance -ProcessId ([int]$ProcessId)}
        ParseProcessCommandLine={param($CommandLine)@(ConvertFrom-CcodControllerProcessCommandLine -CommandLine $CommandLine)}
        GetLegacyTempRoot={[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexControlOtherDevices'))}
        TestLegacyPathSafe={param($Path)Test-CcodControllerLegacySafeRoot -Path $Path}
        TestLegacyFileSafe={param($Path)try{$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;return -not $item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)}catch{return $false}}
        GetFileSha256={param($Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
        GetApprovedPowerShellPath={[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))}
        StartStopwatch={ [Diagnostics.Stopwatch]::StartNew() }
        GetElapsedMilliseconds={param($Clock)[long]$Clock.ElapsedMilliseconds}
        EnterMutex={
            param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)
            if($Kind -ceq 'AccountTransition'){Enter-CcodMutex -Kind $Kind -UserSid $UserSid -TimeoutMilliseconds $TimeoutMilliseconds}
            else{Enter-CcodMutex -Kind $Kind -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds $TimeoutMilliseconds}
        }
        ExitMutex={param($Lease)Exit-CcodMutex -Lease $Lease}
        ReadJournal={param($Path)Read-CcodTransition -Path $Path}
        UtcNow={ [DateTime]::UtcNow }
        EngineInvoker={param($Action,$Request,$Paths,$EngineAdapters)switch($Action){'Inspect'{Invoke-CcodInspectSession -Request $Request -Paths $Paths -Adapters $EngineAdapters}'Close'{Invoke-CcodCloseSession -Request $Request -Paths $Paths -Adapters $EngineAdapters}'Apply'{Invoke-CcodApplySession -Request $Request -Paths $Paths -Adapters $EngineAdapters}'RepairRenderer'{Invoke-CcodRepairRenderer -Request $Request -Paths $Paths -Adapters $EngineAdapters}'Recover'{Invoke-CcodRecoverSession -Request $Request -Paths $Paths -Adapters $EngineAdapters}default{throw 'unsupported controller action'}}}
        AssertLifecycleFence={
            param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$RuntimeId,$InstallRoot)
            $ownership=[pscustomobject][ordered]@{
                schemaVersion=1;lease=[pscustomobject][ordered]@{Released=$false};epoch=[UInt64]$LeaseEpoch;runtimeId=[string]$RuntimeId
                runtimeGeneration=[UInt64]$RuntimeGeneration;ownerIdentity=$OwnerIdentity;released=$false
            }
            Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $ownership
        }
        GetDelegatedOwnership={$null}
        WriteResult={param($Path,$Value)Write-CcodAtomicJson -Path $Path -Value $Value}
        WriteStdout={param($Line)[Console]::Out.WriteLine($Line)}
        WriteStderr={param($Line)[Console]::Error.WriteLine($Line)}
        WriteLog={param($Path,$Message)Write-CcodRotatingLog -Path $Path -Message $Message}
    }
    if($null -ne $Adapters){foreach($key in $Adapters.Keys){$defaults[$key]=$Adapters[$key]}}
    return $defaults
}

function Test-CcodControllerCanonicalSid([object]$Value){
    if($Value -isnot [string]){return $false}
    try{$sid=[Security.Principal.SecurityIdentifier]::new($Value)}catch{return $false}
    return $sid.Value -ceq $Value
}

function Test-CcodControllerCanonicalUtc([object]$Value){
    if($Value -isnot [string]){return $false}
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodControllerPositiveUInt64([object]$Value){
    if($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
       $Value -isnot [sbyte] -and $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64] -and $Value -isnot [decimal]){return $false}
    try{$number=[decimal]$Value;return $number -ge 1 -and $number -le [decimal][UInt64]::MaxValue -and [decimal]::Truncate($number) -eq $number}catch{return $false}
}

function Test-CcodControllerExactProperties($Value,[string[]]$Names){
    if($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])){return $false}
    $actual=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
    if($actual.Count -ne $Names.Count){return $false}
    foreach($name in $Names){if($actual -cnotcontains $name){return $false}}
    return $true
}

function Test-CcodControllerPathEqual([object]$Left,[object]$Right){
    if($Left -isnot [string] -or $Right -isnot [string] -or [string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)){return $false}
    try{return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}

function Test-CcodControllerExactArguments([object[]]$Actual,[object[]]$Expected,[int[]]$PathIndices=@()){
    if($Actual.Count -ne $Expected.Count){return $false}
    for($index=0;$index -lt $Expected.Count;$index++){
        if($PathIndices -contains $index){if(-not (Test-CcodControllerPathEqual $Actual[$index] $Expected[$index])){return $false}}
        elseif($Actual[$index] -isnot [string] -or $Actual[$index] -cne [string]$Expected[$index]){return $false}
    }
    return $true
}

function Test-CcodLegacyWrapperTail {
    param([ValidateSet('start','reset','uninstall')][string]$Prefix,[object[]]$Arguments,[string]$InstallRoot,[string]$InstallerRoot)
    if($Prefix -ceq 'uninstall'){
        return $Arguments.Count -eq 6 -and $Arguments[0] -ceq '-InstallerRoot' -and (Test-CcodControllerPathEqual $Arguments[1] $InstallerRoot) -and
               $Arguments[2] -ceq '-InstallRoot' -and (Test-CcodControllerPathEqual $Arguments[3] $InstallRoot) -and
               $Arguments[4] -ceq '-Mode' -and $Arguments[5] -ceq 'Prepare'
    }
    $seen=@{}
    for($index=0;$index -lt $Arguments.Count;$index++){
        $argument=$Arguments[$index]
        if($argument -isnot [string] -or [string]::IsNullOrWhiteSpace($argument) -or $seen.ContainsKey($argument)){return $false}
        $seen[$argument]=$true
        switch -CaseSensitive ($Prefix){
            'start' {
                if($argument -ceq '-RestartCodex'){continue}
                if(@('-RendererDebugPort','-MainInspectorPort','-TimeoutSeconds') -cnotcontains $argument -or $index+1 -ge $Arguments.Count){return $false}
                $value=$Arguments[++$index];$parsed=0
                if($value -isnot [string] -or -not [int]::TryParse($value,[ref]$parsed)){return $false}
                if($argument -ceq '-TimeoutSeconds'){if($parsed -lt 10 -or $parsed -gt 120){return $false}}
                elseif($parsed -lt 0 -or $parsed -gt 65535){return $false}
            }
            'reset' {
                if(@('-BackupDeviceKeyStore','-DoNotRestart') -cnotcontains $argument){return $false}
            }
        }
    }
    return $true
}

function Test-CcodLegacyRequestSemantics {
    param($Request,[ValidateSet('start','reset','uninstall')][string]$Prefix,[object[]]$Arguments)
    if($Request.action -cne 'Recover' -or $null -ne $Request.source -or $Request.existingOnly -isnot [bool] -or -not $Request.existingOnly -or
        $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or $Request.restartOrdinary -isnot [bool] -or $Request.timeoutMilliseconds -isnot [int]){return $false}
    switch($Prefix){
        'start' {
            if($Arguments -cnotcontains '-RestartCodex' -or -not $Request.restartOrdinary){return $false}
            $timeout=30;$index=[array]::IndexOf($Arguments,'-TimeoutSeconds')
            if($index -ge 0){if($index+1 -ge $Arguments.Count -or -not [int]::TryParse([string]$Arguments[$index+1],[ref]$timeout)){return $false}}
            return $Request.timeoutMilliseconds -eq ($timeout*1000)
        }
        'reset' {
            if($Request.timeoutMilliseconds -ne 30000){return $false}
            return $Request.restartOrdinary -eq ($Arguments -cnotcontains '-DoNotRestart')
        }
        'uninstall' {
            return $Arguments -cnotcontains '-KeepCurrentSpecialSession' -and $Request.restartOrdinary -and $Request.timeoutMilliseconds -eq 30000
        }
    }
    return $false
}

function Test-CcodLegacyRecoverProvenance {
    param($Request,[string]$RequestPath,[string]$ResultPath,$RuntimeContext,[hashtable]$Adapter)
    try{
        $tempRoot=[IO.Path]::GetFullPath([string](& $Adapter.GetLegacyTempRoot))
        if(-not (& $Adapter.TestLegacyPathSafe $tempRoot)){return $false}
        foreach($path in @($RequestPath,$ResultPath)){
            if($path -isnot [string] -or -not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetFullPath($path) -cne $path -or
                -not (Test-CcodControllerPathEqual (Split-Path -Parent $path) $tempRoot) -or -not (& $Adapter.TestLegacyFileSafe $path)){return $false}
        }
        $requestMatch=[regex]::Match((Split-Path -Leaf $RequestPath),'^(?<prefix>start|reset|uninstall)-(?<nonce>[0-9a-f]{32})-request\.json$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
        $resultMatch=[regex]::Match((Split-Path -Leaf $ResultPath),'^(?<prefix>start|reset|uninstall)-(?<nonce>[0-9a-f]{32})-result\.json$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if(-not $requestMatch.Success -or -not $resultMatch.Success -or $requestMatch.Groups['prefix'].Value -cne $resultMatch.Groups['prefix'].Value -or
            $requestMatch.Groups['nonce'].Value -cne $resultMatch.Groups['nonce'].Value){return $false}
        $prefix=$requestMatch.Groups['prefix'].Value

        if($null -eq $RuntimeContext -or $RuntimeContext.RuntimeRoot -isnot [string] -or $RuntimeContext.InstallRoot -isnot [string] -or $RuntimeContext.ControllerPath -isnot [string] -or
            $null -eq $RuntimeContext.Manifest -or $null -eq $RuntimeContext.Manifest.PSObject.Properties['files']){return $false}
        $wrapperLeaf=switch($prefix){'start'{'Start-CodexControlOtherDevices.ps1'}'reset'{'Reset-CodexControlOtherDevices.ps1'}'uninstall'{'src/persistence/UninstallBootstrap.ps1'}}
        $manifestMatches=@($RuntimeContext.Manifest.files|Where-Object{$null -ne $_ -and $null -ne $_.PSObject.Properties['path'] -and $_.path -is [string] -and $_.path -ceq $wrapperLeaf})
        if($manifestMatches.Count -ne 1){return $false}
        $wrapperPath=if($prefix -ceq 'uninstall'){$null}else{[IO.Path]::GetFullPath((Join-Path $RuntimeContext.RuntimeRoot $wrapperLeaf))}
        $expectedController=[IO.Path]::GetFullPath((Join-Path $RuntimeContext.RuntimeRoot 'src\persistence\SessionController.ps1'))
        if(-not (Test-CcodControllerPathEqual $RuntimeContext.ControllerPath $expectedController)){return $false}

        $currentPid=& $Adapter.GetCurrentProcessId
        if($currentPid -isnot [int] -or $currentPid -lt 1){return $false}
        $current=& $Adapter.GetProcessProvenance $currentPid
        $parent=& $Adapter.GetProcessProvenance $Request.supervisorIdentity.pid
        $processFields=@('Pid','CreationTimeUtc','SessionId','UserSid','Path','CommandLine','ParentPid')
        if(-not (Test-CcodControllerExactProperties $current $processFields) -or -not (Test-CcodControllerExactProperties $parent $processFields)){return $false}
        $identity=& $Adapter.GetIdentity;$approvedPowerShell=[IO.Path]::GetFullPath([string](& $Adapter.GetApprovedPowerShellPath))
        if($current.Pid -ne $currentPid -or $current.ParentPid -ne $Request.supervisorIdentity.pid -or $current.SessionId -ne $identity.SessionId -or $current.UserSid -cne $identity.UserSid -or
            $parent.Pid -ne $Request.supervisorIdentity.pid -or $parent.CreationTimeUtc -cne $Request.supervisorIdentity.creationTimeUtc -or
            [string]$parent.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $parent.UserSid -cne $identity.UserSid -or
            -not (Test-CcodControllerPathEqual $current.Path $approvedPowerShell) -or -not (Test-CcodControllerPathEqual $parent.Path $approvedPowerShell)){return $false}

        $childArguments=@(& $Adapter.ParseProcessCommandLine $current.CommandLine)
        $expectedChild=@($approvedPowerShell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$RuntimeContext.ControllerPath,'-RequestPath',$RequestPath,'-ResultPath',$ResultPath)
        if(-not (Test-CcodControllerExactArguments $childArguments $expectedChild @(0,5,7,9))){return $false}
        $parentArguments=@(& $Adapter.ParseProcessCommandLine $parent.CommandLine)
        if($parentArguments.Count -lt 6){return $false}
        $installerRoot=$null
        if($prefix -ceq 'uninstall'){
            try{$wrapperPath=[IO.Path]::GetFullPath([string]$parentArguments[5]);$installerRoot=[IO.Path]::GetFullPath((Split-Path (Split-Path (Split-Path $wrapperPath -Parent) -Parent) -Parent))}catch{return $false}
            $expectedBootstrap=[IO.Path]::GetFullPath((Join-Path $installerRoot 'src\persistence\UninstallBootstrap.ps1'))
            if(-not (Test-CcodControllerPathEqual $wrapperPath $expectedBootstrap) -or
               $null -eq $manifestMatches[0].PSObject.Properties['sha256'] -or $manifestMatches[0].sha256 -isnot [string] -or $manifestMatches[0].sha256 -cnotmatch '^[0-9a-f]{64}$' -or
               -not (& $Adapter.TestLegacyFileSafe $wrapperPath) -or (& $Adapter.GetFileSha256 $wrapperPath) -cne $manifestMatches[0].sha256){return $false}
        }elseif(-not (Test-CcodControllerPathEqual $parentArguments[5] $wrapperPath)){return $false}
        $expectedParent=@($approvedPowerShell,'-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath)
        if(-not (Test-CcodControllerExactArguments @($parentArguments|Select-Object -First 6) $expectedParent @(0,5)) -or
            -not (Test-CcodLegacyWrapperTail -Prefix $prefix -Arguments @($parentArguments|Select-Object -Skip 6) -InstallRoot $RuntimeContext.InstallRoot -InstallerRoot $installerRoot) -or
            -not (Test-CcodLegacyRequestSemantics -Request $Request -Prefix $prefix -Arguments @($parentArguments|Select-Object -Skip 6))){return $false}
        return $true
    }catch{return $false}
}

function Test-CcodControllerLeaseInput {
    param($Request,$Identity,$SupervisorProcess)
    $schema2=$null -ne $Request -and $null -ne $Request.PSObject.Properties['schemaVersion'] -and $Request.schemaVersion -eq 2
    $legacyRecover=$false
    $requestFields=if($schema2){@('schemaVersion','action','transactionId','runtimeId','runtimeGeneration','leaseEpoch','ownerIdentity','supervisorIdentity','source','existingOnly','rendererPort','mainPort','timeoutMilliseconds','restartOrdinary')}else{@('schemaVersion','action','transactionId','runtimeId','supervisorIdentity','source','existingOnly','rendererPort','mainPort','timeoutMilliseconds','restartOrdinary')}
    if((-not $schema2 -and -not $legacyRecover) -or -not (Test-CcodControllerExactProperties $Request $requestFields)){return $false}
    if($null -eq $Request -or ($Request -isnot [pscustomobject] -and $Request -isnot [Collections.IDictionary]) -or
        $null -eq $Request.PSObject.Properties['action'] -or $Request.action -isnot [string] -or $(if($schema2){@('Inspect','Close','Apply','RepairRenderer') -cnotcontains $Request.action}else{$Request.action -cne 'Recover'}) -or
        $null -eq $Request.PSObject.Properties['transactionId'] -or -not (Test-CcodControllerCanonicalGuid $Request.transactionId) -or
        $null -eq $Request.PSObject.Properties['timeoutMilliseconds'] -or $Request.timeoutMilliseconds -isnot [int] -or $Request.timeoutMilliseconds -lt 500 -or $Request.timeoutMilliseconds -gt 120000 -or
        $null -eq $Request.PSObject.Properties['supervisorIdentity'] -or $null -eq $Request.supervisorIdentity -or
        $null -eq $Request.supervisorIdentity.PSObject.Properties['pid'] -or $Request.supervisorIdentity.pid -isnot [int] -or $Request.supervisorIdentity.pid -lt 1 -or
        $null -eq $Request.supervisorIdentity.PSObject.Properties['creationTimeUtc'] -or -not (Test-CcodControllerCanonicalUtc $Request.supervisorIdentity.creationTimeUtc) -or
        $null -eq $Request.supervisorIdentity.PSObject.Properties['sessionId'] -or $Request.supervisorIdentity.sessionId -isnot [string] -or
        $null -eq $Identity -or ($Identity -isnot [pscustomobject] -and $Identity -isnot [Collections.IDictionary]) -or
        $null -eq $Identity.PSObject.Properties['UserSid'] -or -not (Test-CcodControllerCanonicalSid $Identity.UserSid) -or
        $null -eq $Identity.PSObject.Properties['SessionId'] -or $Identity.SessionId -isnot [int] -or $Identity.SessionId -lt 0 -or
        $null -eq $SupervisorProcess -or ($SupervisorProcess -isnot [pscustomobject] -and $SupervisorProcess -isnot [Collections.IDictionary]) -or
        $null -eq $SupervisorProcess.PSObject.Properties['Pid'] -or $SupervisorProcess.Pid -isnot [int] -or
        $null -eq $SupervisorProcess.PSObject.Properties['CreationTimeUtc'] -or $SupervisorProcess.CreationTimeUtc -isnot [string] -or
        $null -eq $SupervisorProcess.PSObject.Properties['SessionId'] -or $SupervisorProcess.SessionId -isnot [int]){return $false}
    if($schema2){
        if(-not (Test-CcodControllerPositiveUInt64 $Request.runtimeGeneration) -or -not (Test-CcodControllerPositiveUInt64 $Request.leaseEpoch) -or
            -not (Test-CcodControllerExactProperties $Request.ownerIdentity @('pid','creationTimeUtc')) -or
            ($Request.ownerIdentity.pid -isnot [int] -and $Request.ownerIdentity.pid -isnot [long]) -or $Request.ownerIdentity.pid -lt 1 -or $Request.ownerIdentity.pid -gt [int]::MaxValue -or
            -not (Test-CcodControllerCanonicalUtc $Request.ownerIdentity.creationTimeUtc)){return $false}
    }
    $canonicalSession=$Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)
    return $Request.supervisorIdentity.sessionId -ceq $canonicalSession -and
        $SupervisorProcess.Pid -eq $Request.supervisorIdentity.pid -and
        $SupervisorProcess.CreationTimeUtc -ceq $Request.supervisorIdentity.creationTimeUtc -and
        $SupervisorProcess.SessionId -eq $Identity.SessionId
}

function Get-CcodControllerRemainingBudget {
    param([int]$Total,$Clock,[hashtable]$Adapter)
    $elapsed=& $Adapter.GetElapsedMilliseconds $Clock
    if(($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0){throw 'invalid monotonic clock'}
    if($elapsed -ge $Total){return [int]0}
    return [int]($Total-[long]$elapsed)
}

function Throw-CcodControllerLeaseInvalid {
    $exception=[InvalidOperationException]::new('The kernel lease contract is invalid.')
    throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_KERNEL_LEASE_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
}

function Assert-CcodControllerLeaseResult {
    param($Lease,[string]$Kind,$Identity,[string]$ExpectedState='Entered')
    $expected=@('SchemaVersion','Name','Kind','Outcome','CreatedNew','Abandoned','Handle','OwnerManagedThreadId','Released')
    if($null -eq $Lease -or $Lease -isnot [pscustomobject]){Throw-CcodControllerLeaseInvalid}
    $actual=@($Lease.PSObject.Properties.Name)
    if($actual.Count -ne $expected.Count){Throw-CcodControllerLeaseInvalid}
    for($index=0;$index -lt $expected.Count;$index++){
        if($actual[$index] -cne $expected[$index] -or $Lease.PSObject.Properties[$expected[$index]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){Throw-CcodControllerLeaseInvalid}
    }
    if($Lease.SchemaVersion -isnot [int] -or $Lease.SchemaVersion -ne 1 -or
        $Lease.Name -isnot [string] -or $Lease.Kind -isnot [string] -or $Lease.Kind -cne $Kind -or
        $Lease.Outcome -isnot [string] -or @('Acquired','TimedOut') -cnotcontains $Lease.Outcome -or
        $Lease.CreatedNew -isnot [bool] -or $Lease.Abandoned -isnot [bool] -or $Lease.Released -isnot [bool]){Throw-CcodControllerLeaseInvalid}
    try{
        $expectedName=if($Kind -ceq 'AccountTransition'){
            Get-CcodKernelObjectName -Kind $Kind -UserSid $Identity.UserSid
        }else{
            Get-CcodKernelObjectName -Kind $Kind -UserSid $Identity.UserSid -SessionId $Identity.SessionId
        }
    }catch{Throw-CcodControllerLeaseInvalid}
    if($Lease.Name -cne $expectedName){Throw-CcodControllerLeaseInvalid}
    if($ExpectedState -ceq 'Released'){
        if($Lease.Outcome -cne 'Acquired' -or $null -ne $Lease.Handle -or $Lease.OwnerManagedThreadId -isnot [int] -or
            $Lease.OwnerManagedThreadId -le 0 -or $Lease.OwnerManagedThreadId -ne [Threading.Thread]::CurrentThread.ManagedThreadId -or -not $Lease.Released){Throw-CcodControllerLeaseInvalid}
        return
    }
    if($ExpectedState -cne 'Entered'){Throw-CcodControllerLeaseInvalid}
    if($Lease.Outcome -ceq 'TimedOut'){
        if($Lease.Abandoned -or $null -ne $Lease.Handle -or $null -ne $Lease.OwnerManagedThreadId -or -not $Lease.Released){Throw-CcodControllerLeaseInvalid}
        return
    }
    if($Lease.Handle -isnot [Threading.Mutex] -or $Lease.OwnerManagedThreadId -isnot [int] -or
        $Lease.OwnerManagedThreadId -le 0 -or $Lease.OwnerManagedThreadId -ne [Threading.Thread]::CurrentThread.ManagedThreadId -or $Lease.Released){Throw-CcodControllerLeaseInvalid}
    try{
        $safeHandle=$Lease.Handle.SafeWaitHandle
        if($null -eq $safeHandle -or $safeHandle.IsClosed -or $safeHandle.IsInvalid){Throw-CcodControllerLeaseInvalid}
    }catch{Throw-CcodControllerLeaseInvalid}
}

function Get-CcodControllerStableLeaseCode {
    param($Failure)
    if($null -ne $Failure -and $Failure.FullyQualifiedErrorId -is [string]){
        $id=($Failure.FullyQualifiedErrorId -split ',')[0]
        if(@('CCOD_KERNEL_INPUT_INVALID','CCOD_KERNEL_ACL_MISMATCH','CCOD_KERNEL_OBJECT_TYPE_MISMATCH','CCOD_KERNEL_ACCESS_DENIED','CCOD_KERNEL_OPEN_FAILED','CCOD_KERNEL_LEASE_INVALID','CCOD_KERNEL_RELEASE_FAILED') -ccontains $id){return $id}
    }
    return 'CCOD_KERNEL_OPEN_FAILED'
}

function Get-CcodControllerStableTransitionCode {
    param($Failure)
    $allowed=@('CCOD_TRANSITION_INVALID','CCOD_TRANSITION_CONFLICT','CCOD_TRANSITION_STAGE_INVALID','CCOD_TRANSITION_COMPLETION_INVALID','CCOD_TRANSITION_ARCHIVE_FAILED','CCOD_TRANSITION_RECEIPT_INVALID')
    if($null -ne $Failure -and $Failure.FullyQualifiedErrorId -is [string]){
        $id=($Failure.FullyQualifiedErrorId -split ',')[0]
        if($allowed -ccontains $id){return $id}
    }
    return 'CCOD_TRANSITION_INVALID'
}

function Test-CcodControllerLegacyRecoverInput {
    param($Request,$Identity,$SupervisorProcess)
    $fields=@('schemaVersion','action','transactionId','runtimeId','supervisorIdentity','source','existingOnly','rendererPort','mainPort','timeoutMilliseconds','restartOrdinary')
    if(-not (Test-CcodControllerExactProperties $Request $fields) -or $Request.schemaVersion -ne 1 -or $Request.action -cne 'Recover' -or
        -not (Test-CcodControllerCanonicalGuid $Request.transactionId) -or $Request.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.runtimeId) -or
        $null -ne $Request.source -or $Request.existingOnly -isnot [bool] -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or
        $Request.timeoutMilliseconds -isnot [int] -or $Request.timeoutMilliseconds -lt 500 -or $Request.timeoutMilliseconds -gt 120000 -or $Request.restartOrdinary -isnot [bool] -or
        -not (Test-CcodControllerExactProperties $Request.supervisorIdentity @('pid','creationTimeUtc','sessionId')) -or
        $Request.supervisorIdentity.pid -isnot [int] -or $Request.supervisorIdentity.pid -lt 1 -or -not (Test-CcodControllerCanonicalUtc $Request.supervisorIdentity.creationTimeUtc) -or
        $Request.supervisorIdentity.sessionId -isnot [string] -or $null -eq $Identity -or -not (Test-CcodControllerCanonicalSid $Identity.UserSid) -or
        $Identity.SessionId -isnot [int] -or $null -eq $SupervisorProcess -or $SupervisorProcess.Pid -isnot [int] -or
        $SupervisorProcess.CreationTimeUtc -isnot [string] -or $SupervisorProcess.SessionId -isnot [int]){return $false}
    return $Request.supervisorIdentity.sessionId -ceq $Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture) -and
        $SupervisorProcess.Pid -eq $Request.supervisorIdentity.pid -and $SupervisorProcess.CreationTimeUtc -ceq $Request.supervisorIdentity.creationTimeUtc -and
        $SupervisorProcess.SessionId -eq $Identity.SessionId
}

function Test-CcodControllerLifecycleFenceFailure($Failure){
    if($null -eq $Failure){return $false}
    $id=[string]$Failure.FullyQualifiedErrorId
    if($id.Contains(',')){$id=$id.Split(',')[0]}
    return $id -ceq 'CCOD_LIFECYCLE_FENCE_STALE'
}

function Assert-CcodControllerMutationFence($Request,$Paths,[hashtable]$Adapter){
    if($null -eq $Request -or $null -eq $Request.PSObject.Properties['schemaVersion'] -or $Request.schemaVersion -ne 2){return}
    $installRoot=Split-Path -Parent $Paths.StateRoot
    try{[void](& $Adapter.AssertLifecycleFence $Request.runtimeGeneration $Request.leaseEpoch $Request.ownerIdentity $Request.runtimeId $installRoot)}catch{
        if(Test-CcodControllerLifecycleFenceFailure $_){throw}
        $exception=[InvalidOperationException]::new('The lifecycle owner is stale.')
        throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$Request.ownerIdentity)
    }
}

function Test-CcodControllerDelegatedOwnership($Request,$Identity,$Delegation){
    try{
        if(-not(Test-CcodControllerExactProperties $Delegation @('schemaVersion','lease','epoch','runtimeId','runtimeGeneration','ownerIdentity','released'))-or$Delegation.schemaVersion-ne1-or$Delegation.released-isnot[bool]-or$Delegation.released-or
            $Delegation.epoch-ne$Request.leaseEpoch-or$Delegation.runtimeId-cne$Request.runtimeId-or$Delegation.runtimeGeneration-ne$Request.runtimeGeneration-or
            -not(Test-CcodControllerExactProperties $Delegation.ownerIdentity @('pid','creationTimeUtc'))-or$Delegation.ownerIdentity.pid-ne$Request.ownerIdentity.pid-or$Delegation.ownerIdentity.creationTimeUtc-cne$Request.ownerIdentity.creationTimeUtc){return $false}
        Assert-CcodControllerLeaseResult $Delegation.lease 'AccountTransition' $Identity
        return $Delegation.lease.Outcome-ceq'Acquired'-and-not$Delegation.lease.Released
    }catch{return $false}
}

function Write-CcodControllerFencedResult($Request,$Paths,[string]$ResultPath,$Value,[hashtable]$Adapter){
    Assert-CcodControllerMutationFence $Request $Paths $Adapter
    & $Adapter.WriteResult $ResultPath $Value|Out-Null
}

function Invoke-CcodSessionController {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,[Parameter(Mandatory)][string]$ResultPath,[hashtable]$Adapters)
    $adapter=Get-CcodControllerAdapters $Adapters;$result=$null;$intendedResult=$null;$diagnosticWritten=$false;$accountLease=$null;$sessionLease=$null;$accountLeaseAcquired=$false;$sessionLeaseAcquired=$false;$releaseFailed=$false;$provisionalRequired=$false;$initialResultWriteFailed=$false
    try{
        try{$identity=& $adapter.GetIdentity}catch{$identity=$null}
        try{$supervisorProcess=& $adapter.GetSupervisorProcess $Request.supervisorIdentity.pid}catch{$supervisorProcess=$null}
        $leaseInputValid=Test-CcodControllerLeaseInput $Request $identity $supervisorProcess
        if(-not $leaseInputValid){
            $result=New-CcodControllerErrorResult $Request 'CCOD_REQUEST_INVALID' 'InputValidation' 'The request does not match this controller session.'
        }else{
            $delegatedOwnership=$null
            if($Request.schemaVersion-eq2){try{$delegatedOwnership=&$adapter.GetDelegatedOwnership}catch{};if(-not(Test-CcodControllerDelegatedOwnership $Request $identity $delegatedOwnership)){$result=New-CcodControllerErrorResult $Request 'CCOD_REQUEST_INVALID' 'InputValidation' 'The request has no verified LifecycleWorker delegation.'}}
        }
        if($null-eq$result){
            $total=[Math]::Min([int]$Request.timeoutMilliseconds,5000)
            try{
                $clock=& $adapter.StartStopwatch
                if($Request.schemaVersion-eq2){Assert-CcodControllerMutationFence $Request $Paths $adapter}
                $remaining=Get-CcodControllerRemainingBudget $total $clock $adapter
                $accountLease=& $adapter.EnterMutex 'AccountTransition' $identity.UserSid $null $remaining
                Assert-CcodControllerLeaseResult $accountLease 'AccountTransition' $identity
                if($accountLease.Outcome -ceq 'TimedOut'){$result=New-CcodControllerErrorResult $Request 'CCOD_TRANSITION_BUSY' 'LeaseAcquire' 'The transition lease is busy.'}
                else{$accountLeaseAcquired=$true}
                if($null-eq$result){
                    $remaining=Get-CcodControllerRemainingBudget $total $clock $adapter
                    $sessionLease=& $adapter.EnterMutex 'Transition' $identity.UserSid $identity.SessionId $remaining
                    Assert-CcodControllerLeaseResult $sessionLease 'Transition' $identity
                    if($sessionLease.Outcome -ceq 'TimedOut'){$result=New-CcodControllerErrorResult $Request 'CCOD_TRANSITION_BUSY' 'LeaseAcquire' 'The transition lease is busy.'}
                    else{
                        $sessionLeaseAcquired=$true
                        if(($accountLeaseAcquired-and$accountLease.Abandoned)-or$sessionLease.Abandoned){[void](Write-CcodControllerAbandonedWarning $Request $Paths $adapter)}
                        try{$active=& $adapter.ReadJournal $Paths.TransitionPath}catch{
                            $code=Get-CcodControllerStableTransitionCode $_
                            $result=New-CcodControllerErrorResult $Request $code 'JournalPreflight' 'The transition journal failed strict validation.'
                            $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
                        }
                        if($null -eq $result){
                            if($null -ne $active){$result=New-CcodControllerErrorResult $Request 'CCOD_TRANSITION_REPLAY_REQUIRED' 'ReplayRequired' 'An active transition requires recovery.'}
                            else{
                                try{
                                    $engineAdapters=@{AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity)& $adapter.AssertLifecycleFence $RuntimeGeneration $LeaseEpoch $OwnerIdentity $Request.runtimeId (Split-Path -Parent $Paths.StateRoot)}.GetNewClosure()}
                                    $output=@(& $adapter.EngineInvoker $Request.action $Request $Paths $engineAdapters)
                                    $candidates=@($output|Where-Object{$_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['schemaVersion']})
                                    if($candidates.Count -ne 1){throw 'engine returned zero or multiple framed result objects'}
                                    $result=$candidates[0];Assert-CcodControllerEngineResult $result $Request
                                }catch{
                                    if(Test-CcodControllerLifecycleFenceFailure $_){throw}
                                    $result=New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' 'EngineResult' $_.Exception.Message
                                    $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
                                }
                            }
                        }
                    }
                }
            }catch{
                if(Test-CcodControllerLifecycleFenceFailure $_){throw}
                $result=New-CcodControllerErrorResult $Request (Get-CcodControllerStableLeaseCode $_) 'LeaseAcquire' 'The transition lease could not be acquired safely.'
                $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
            }
        }
        $intendedResult=$result
        $provisionalRequired=$accountLeaseAcquired -or $sessionLeaseAcquired
        $valueToPersist=if($provisionalRequired){New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' 'ResultWrite' 'Controller completion has not been published.'}else{$result}
        try{Write-CcodControllerFencedResult $Request $Paths $ResultPath $valueToPersist $adapter}catch{
            if(Test-CcodControllerLifecycleFenceFailure $_){throw}
            $initialResultWriteFailed=$true
            $result=New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' 'ResultWrite' $_.Exception.Message
            if(-not $diagnosticWritten){$diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter}
            try{& $adapter.WriteStderr 'CCOD_CONTROLLER_RESULT_WRITE_FAILED: result persistence failed'|Out-Null}catch{}
        }
    }finally{
        if($sessionLeaseAcquired){try{$released=& $adapter.ExitMutex $sessionLease;if($released -isnot [bool] -or -not $released){Throw-CcodControllerLeaseInvalid};Assert-CcodControllerLeaseResult $sessionLease 'Transition' $identity 'Released'}catch{$releaseFailed=$true}}
        if($accountLeaseAcquired){try{$released=& $adapter.ExitMutex $accountLease;if($released -isnot [bool] -or -not $released){Throw-CcodControllerLeaseInvalid};Assert-CcodControllerLeaseResult $accountLease 'AccountTransition' $identity 'Released'}catch{$releaseFailed=$true}}
    }
    if($provisionalRequired){
        if($releaseFailed){
            $result=New-CcodControllerErrorResult $Request 'CCOD_KERNEL_RELEASE_FAILED' 'LeaseRelease' 'The transition lease could not be released safely.'
            $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
        }elseif(-not $initialResultWriteFailed){$result=$intendedResult}
        try{Write-CcodControllerFencedResult $Request $Paths $ResultPath $result $adapter}catch{
            if(Test-CcodControllerLifecycleFenceFailure $_){throw}
            $result=New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' 'ResultWrite' 'The corrected controller result could not be persisted.'
            [void](Write-CcodControllerDiagnostic $result $Request $Paths $adapter)
            try{& $adapter.WriteStderr 'CCOD_CONTROLLER_RESULT_WRITE_FAILED: result persistence failed'|Out-Null}catch{}
        }
    }
    $line=$result|ConvertTo-Json -Depth 16 -Compress
    & $adapter.WriteStdout $line|Out-Null
    $safe=@('Activated','Inspected','NoAction','Recovered','Closed') -ccontains $result.outcome
    return [pscustomobject][ordered]@{Result=$result;ExitCode=if($safe){0}else{1}}
}

function Get-CcodControllerInstallRoot {
    $localAppData=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    if([string]::IsNullOrWhiteSpace($localAppData)){$localAppData=[Environment]::GetFolderPath('LocalApplicationData')}
    if([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)){throw 'LOCALAPPDATA is unavailable'}
    return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($localAppData)) 'CodexControlOtherDevices'))
}

function Resolve-CcodControllerRuntime {
    param([string]$InstallRoot=(Get-CcodControllerInstallRoot),[string]$ControllerPath=$script:CcodControllerScriptPath)
    try{
        $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot
        $runtimeRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
        $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $active.activeRuntime
        $expectedController=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\SessionController.ps1'))
        if(-not $validation.Valid -or [IO.Path]::GetFullPath($ControllerPath) -cne $expectedController){throw 'active runtime mismatch'}
        return [pscustomobject][ordered]@{InstallRoot=[IO.Path]::GetFullPath($InstallRoot);RuntimeRoot=$runtimeRoot;RuntimeId=$active.activeRuntime;ControllerPath=$expectedController;Manifest=$validation.Manifest}
    }catch{
        $exception=[InvalidOperationException]::new('This controller is not the manifest-verified active installed runtime.')
        throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_RUNTIME_UNAUTHORIZED',[Management.Automation.ErrorCategory]::SecurityError,$ControllerPath)
    }
}

function Get-CcodInstalledControllerPaths {
    param([Parameter(Mandatory)]$RuntimeContext)
    $runtimeRoot=$RuntimeContext.RuntimeRoot;$installRoot=$RuntimeContext.InstallRoot
    $stateRoot=[IO.Path]::GetFullPath((Join-Path $installRoot 'state'))
    [pscustomobject][ordered]@{
        StateRoot=$stateRoot
        TransitionPath=[IO.Path]::GetFullPath((Join-Path $stateRoot 'transition.json'))
        TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $installRoot 'logs\transactions.log'))
        SessionLogPath=[IO.Path]::GetFullPath((Join-Path $installRoot 'logs\session.log'))
        CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\check-package.mjs'))
        OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\orchestrator.js'))
        MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\main-payload.js'))
    }
}

function New-CcodManualControllerRequest {
    param([string]$Action,[string]$RuntimeId,[UInt64]$RuntimeGeneration=1,[UInt64]$LeaseEpoch=1,$OwnerIdentity,$SupervisorIdentity,[bool]$ExistingOnly,$RendererPort,$MainPort,[int]$TimeoutMilliseconds,[bool]$RestartOrdinary,[string]$TransactionId=([guid]::NewGuid().ToString('D')))
    if($null -eq $OwnerIdentity){$OwnerIdentity=[pscustomobject][ordered]@{pid=[int]$SupervisorIdentity.pid;creationTimeUtc=[string]$SupervisorIdentity.creationTimeUtc}}
    [pscustomobject][ordered]@{schemaVersion=2;action=$Action;transactionId=$TransactionId;runtimeId=$RuntimeId;runtimeGeneration=$RuntimeGeneration;leaseEpoch=$LeaseEpoch;ownerIdentity=$OwnerIdentity;supervisorIdentity=$SupervisorIdentity;source=$null;existingOnly=$ExistingOnly;rendererPort=$RendererPort;mainPort=$MainPort;timeoutMilliseconds=$TimeoutMilliseconds;restartOrdinary=$RestartOrdinary}
}

if($MyInvocation.InvocationName -ne '.'){
    if($PSCmdlet.ParameterSetName -ceq 'Supervisor' -and ([string]::IsNullOrWhiteSpace($RequestPath) -or [string]::IsNullOrWhiteSpace($ResultPath) -or -not [IO.Path]::IsPathRooted($RequestPath) -or -not [IO.Path]::IsPathRooted($ResultPath) -or [IO.Path]::GetFullPath($RequestPath) -cne $RequestPath -or [IO.Path]::GetFullPath($ResultPath) -cne $ResultPath)){
        $failure=New-CcodControllerErrorResult $null 'CCOD_REQUEST_INVALID' 'InputValidation' 'Canonical absolute RequestPath and ResultPath are required'
        [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
    }
    try{$runtimeContext=Resolve-CcodControllerRuntime}catch{
        $failure=New-CcodControllerErrorResult $null 'CCOD_RUNTIME_UNAUTHORIZED' 'RuntimeAuthorization' 'The active installed runtime could not be verified.'
        if($PSCmdlet.ParameterSetName -ceq 'Supervisor'){try{Write-CcodAtomicJson -Path $ResultPath -Value $failure}catch{}}
        [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
    }
    $paths=Get-CcodInstalledControllerPaths -RuntimeContext $runtimeContext
    $legacyRequest=$false
    if($PSCmdlet.ParameterSetName -ceq 'Supervisor'){
        try{$request=Read-CcodStrictJson -Path $RequestPath -ExpectedSchema 2 -Kind 'session controller request'}catch{
            $readFailure=$_;$readCode=[string]$_.FullyQualifiedErrorId;if($readCode.Contains(',')){$readCode=$readCode.Split(',')[0]}
            if($readCode -ceq 'CCOD_SCHEMA_UNSUPPORTED'){
                try{$request=Read-CcodStrictJson -Path $RequestPath -ExpectedSchema 1 -Kind 'session controller request';$legacyRequest=$true}catch{$readFailure=$_;$request=$null}
            }else{$request=$null}
            if($null -eq $request){
                $failure=New-CcodControllerErrorResult $null 'CCOD_REQUEST_INVALID' 'InputValidation' $readFailure.Exception.Message
                try{Write-CcodAtomicJson -Path $ResultPath -Value $failure}catch{}
                [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
            }
        }
        if($request.runtimeId -isnot [string] -or $request.runtimeId -cne $runtimeContext.RuntimeId){
            $failure=New-CcodControllerErrorResult $request 'CCOD_RUNTIME_UNAUTHORIZED' 'RuntimeAuthorization' 'The request runtime does not match the active installed runtime.'
            try{Write-CcodAtomicJson -Path $ResultPath -Value $failure}catch{}
            [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
        }
    } else {
        if([string]::IsNullOrWhiteSpace($Action)){
            $failure=New-CcodControllerErrorResult $null 'CCOD_REQUEST_INVALID' 'InputValidation' 'A manual Action is required'
            [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
        }
        $runtimeId=$runtimeContext.RuntimeId
        $process=[Diagnostics.Process]::GetCurrentProcess()
        try{$created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$sessionId=[string]$process.SessionId}finally{$process.Dispose()}
        $request=New-CcodManualControllerRequest -Action $Action -RuntimeId $runtimeId -SupervisorIdentity ([pscustomobject][ordered]@{pid=$PID;creationTimeUtc=$created;sessionId=$sessionId}) -ExistingOnly $ExistingOnly -RendererPort $RendererPort -MainPort $MainPort -TimeoutMilliseconds $TimeoutMilliseconds -RestartOrdinary $RestartOrdinary
        $resultDirectory=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexControlOtherDevices'))
        [IO.Directory]::CreateDirectory($resultDirectory)|Out-Null;$ResultPath=[IO.Path]::GetFullPath((Join-Path $resultDirectory ("manual-$($request.transactionId).json")))
    }
    if($legacyRequest){
        $resolvedLegacyAdapters=Get-CcodControllerAdapters $null
        $legacyAuthorized=Test-CcodLegacyRecoverProvenance -Request $request -RequestPath $RequestPath -ResultPath $ResultPath -RuntimeContext $runtimeContext -Adapter $resolvedLegacyAdapters
        if($legacyAuthorized){
            $legacyExecution={
                param($LegacyRequest,$LegacyPaths,[string]$LegacyResultPath,[hashtable]$LegacyAdapter)
                $legacyResult=$null;$accountLease=$null;$sessionLease=$null;$identity=$null;$releaseFailed=$false
                try{
                    $identity=& $LegacyAdapter.GetIdentity
                    $supervisor=& $LegacyAdapter.GetSupervisorProcess $LegacyRequest.supervisorIdentity.pid
                    if(-not (Test-CcodControllerLegacyRecoverInput $LegacyRequest $identity $supervisor)){throw 'legacy input changed after provenance'}
                    $clock=& $LegacyAdapter.StartStopwatch;$total=[Math]::Min([int]$LegacyRequest.timeoutMilliseconds,5000)
                    $accountLease=& $LegacyAdapter.EnterMutex 'AccountTransition' $identity.UserSid $null (Get-CcodControllerRemainingBudget $total $clock $LegacyAdapter)
                    Assert-CcodControllerLeaseResult $accountLease 'AccountTransition' $identity
                    if($accountLease.Outcome -cne 'Acquired'){throw 'legacy account transition lease is busy'}
                    $sessionLease=& $LegacyAdapter.EnterMutex 'Transition' $identity.UserSid $identity.SessionId (Get-CcodControllerRemainingBudget $total $clock $LegacyAdapter)
                    Assert-CcodControllerLeaseResult $sessionLease 'Transition' $identity
                    if($sessionLease.Outcome -cne 'Acquired'){throw 'legacy session transition lease is busy'}
                    $output=@(& $LegacyAdapter.EngineInvoker 'Recover' $LegacyRequest $LegacyPaths @{})
                    $candidates=@($output|Where-Object{$_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['schemaVersion']})
                    if($candidates.Count -ne 1){throw 'legacy engine returned invalid framing'}
                    $legacyResult=$candidates[0];Assert-CcodControllerEngineResult $legacyResult $LegacyRequest
                }catch{
                    $legacyResult=New-CcodControllerErrorResult $LegacyRequest 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' 'LegacyRecover' 'Legacy recovery failed safely.'
                }finally{
                    if($null -ne $sessionLease -and $sessionLease.Outcome -ceq 'Acquired'){try{if(-not (& $LegacyAdapter.ExitMutex $sessionLease)){$releaseFailed=$true}}catch{$releaseFailed=$true}}
                    if($null -ne $accountLease -and $accountLease.Outcome -ceq 'Acquired'){try{if(-not (& $LegacyAdapter.ExitMutex $accountLease)){$releaseFailed=$true}}catch{$releaseFailed=$true}}
                }
                if($releaseFailed){$legacyResult=New-CcodControllerErrorResult $LegacyRequest 'CCOD_KERNEL_RELEASE_FAILED' 'LeaseRelease' 'Legacy recovery lease release failed safely.'}
                try{& $LegacyAdapter.WriteResult $LegacyResultPath $legacyResult|Out-Null}catch{$legacyResult=New-CcodControllerErrorResult $LegacyRequest 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' 'ResultWrite' 'Legacy recovery result write failed safely.'}
                & $LegacyAdapter.WriteStdout ($legacyResult|ConvertTo-Json -Depth 16 -Compress)|Out-Null
                $safe=@('NoAction','Recovered','Closed') -ccontains $legacyResult.outcome
                [pscustomobject][ordered]@{Result=$legacyResult;ExitCode=if($safe){0}else{1}}
            }
            $run=& $legacyExecution $request $paths $ResultPath $resolvedLegacyAdapters;$legacyExecution=$null
        }
        else{$run=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $ResultPath}
    }else{$run=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $ResultPath}
    exit $run.ExitCode
}
