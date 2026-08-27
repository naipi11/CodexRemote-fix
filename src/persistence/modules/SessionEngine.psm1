Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $moduleRoot 'CompatibilityProbe.psm1') -Force
Import-Module (Join-Path $moduleRoot 'PersistenceIO.psm1') -Force
Import-Module (Join-Path $moduleRoot 'StateStore.psm1') -Force
Import-Module (Join-Path $moduleRoot 'ProcessControl.psm1') -Force
Import-Module (Join-Path $moduleRoot 'RendererIntegration.psm1') -Force
Import-Module (Join-Path $moduleRoot 'TransitionJournal.psm1') -Force

$script:CcodSessionStableErrorCodes=@(
    'BRIDGE_PROOF_INCOMPLETE',
    'CCOD_ATOMIC_NAME_EXHAUSTED','CCOD_ATOMIC_NAME_INVALID','CCOD_ATOMIC_RECOVERY_FAILED','CCOD_ATOMIC_REPLACE_FAILED',
    'CCOD_BRIDGE_JSON_INVALID','CCOD_CLOCK_INVALID','CCOD_CLOSE_UNPROVEN','CCOD_CODEX_HOME_INVALID','CCOD_LIFECYCLE_FENCE_STALE',
    'CCOD_LIVE_PROBE_INVALID','CCOD_LIVE_PROBE_MISMATCH','CCOD_LIVE_PROBE_REQUIRED','CCOD_LOG_ENTRY_TOO_LARGE',
    'CCOD_MAIN_INSPECTOR_OPEN','CCOD_NODE_CANDIDATE_INVALID','CCOD_PATH_MISSING','CCOD_PATH_OUTSIDE_ROOT','CCOD_PATHS_INVALID',
    'CCOD_PORT_UNAVAILABLE','CCOD_RECOVERY_UNPROVEN','CCOD_REPARSE_PATH','CCOD_REPLAY_INPUT_INVALID','CCOD_REQUEST_INVALID',
    'CCOD_SCHEMA_UNSUPPORTED','CCOD_SESSION_FAILED','CCOD_SETTINGS_INVALID','CCOD_SOURCE_AMBIGUOUS','CCOD_SOURCE_CHANGED',
    'CCOD_SPECIAL_START_FAILED','CCOD_STALE_PACKAGE_AMBIGUOUS','CCOD_STALE_PACKAGE_UNPROVEN','CCOD_STATE_ALREADY_INITIALIZED','CCOD_STATE_BLOCKED','CCOD_STATE_MALFORMED','CCOD_STATE_MISSING','CCOD_STATE_STALE_PACKAGE',
    'CCOD_STATUS_INVALID','CCOD_STOP_UNCONFIRMED','CCOD_TRANSITION_ARCHIVE_FAILED','CCOD_TRANSITION_COMPLETION_INVALID',
    'CCOD_TRANSITION_CONFLICT','CCOD_TRANSITION_INVALID','CCOD_TRANSITION_RECEIPT_INVALID','CCOD_TRANSITION_STAGE_INVALID',
    'CCOD_VERIFIED_PACKAGES_INVALID'
)

function Throw-CcodSessionError {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message, $Target)
    $exception = [InvalidOperationException]::new($Message)
    $record = [Management.Automation.ErrorRecord]::new($exception, $Code, [Management.Automation.ErrorCategory]::InvalidData, $Target)
    throw $record
}

function Assert-CcodSessionExactProperties {
    param($Value, [string[]]$Expected, [string]$Code, [string]$Kind)
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) {
        Throw-CcodSessionError $Code "$Kind must be an exact object" $Value
    }
    $actual = @($Value.PSObject.Properties.Name)
    if ($Value -is [Collections.IDictionary]) { $actual = @($Value.Keys) }
    if ($actual.Count -ne $Expected.Count) { Throw-CcodSessionError $Code "$Kind fields are invalid" $Value }
    foreach ($name in $Expected) { if ($actual -cnotcontains $name) { Throw-CcodSessionError $Code "$Kind fields are invalid" $Value } }
}

function Test-CcodSessionCanonicalUtc([object]$Value) {
    if ($Value -isnot [string]) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodSessionCanonicalGuid([object]$Value) {
    if ($Value -isnot [string]) { return $false }
    $parsed = [guid]::Empty
    return [guid]::TryParseExact($Value, 'D', [ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodSessionPositiveUInt64([object]$Value) {
    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [sbyte] -and $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64] -and $Value -isnot [decimal]) { return $false }
    try {
        $number=[decimal]$Value
        return $number -ge 1 -and $number -le [decimal][UInt64]::MaxValue -and [decimal]::Truncate($number) -eq $number
    } catch { return $false }
}

function Assert-CcodSessionSnapshot {
    param($Snapshot)
    Assert-CcodSessionExactProperties $Snapshot @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort') 'CCOD_REQUEST_INVALID' 'source'
    if (($Snapshot.Pid -isnot [int] -and $Snapshot.Pid -isnot [long]) -or $Snapshot.Pid -lt 1 -or $Snapshot.Pid -gt [int]::MaxValue -or
        -not (Test-CcodSessionCanonicalUtc $Snapshot.CreationTimeUtc) -or $Snapshot.SessionId -isnot [int] -or
        $Snapshot.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.UserSid) -or
        $Snapshot.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.Path) -or
        $Snapshot.PackageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.PackageFamilyName) -or
        $Snapshot.CommandLine -isnot [string] -or $Snapshot.IsTopLevel -isnot [bool] -or
        @('Ordinary','Special','Unrelated') -cnotcontains $Snapshot.Mode) {
        Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'source snapshot is invalid' $Snapshot
    }
    foreach ($name in @('RendererPort','MainPort')) {
        $value = $Snapshot.$name
        if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 65535)) {
            Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'source snapshot port is invalid' $Snapshot
        }
    }
}

function Assert-CcodSessionRequest {
    param($Request, [string]$ExpectedAction)
    $schema2=$null -ne $Request -and $null -ne $Request.PSObject.Properties['schemaVersion'] -and $Request.schemaVersion -eq 2
    if($schema2){
        Assert-CcodSessionExactProperties $Request @('schemaVersion','action','transactionId','runtimeId','runtimeGeneration','leaseEpoch','ownerIdentity','supervisorIdentity','source','existingOnly','rendererPort','mainPort','timeoutMilliseconds','restartOrdinary') 'CCOD_REQUEST_INVALID' 'request'
    }else{
        Assert-CcodSessionExactProperties $Request @('schemaVersion','action','transactionId','runtimeId','supervisorIdentity','source','existingOnly','rendererPort','mainPort','timeoutMilliseconds','restartOrdinary') 'CCOD_REQUEST_INVALID' 'request'
    }
    $allowed=if($schema2){@('Inspect','Close','Apply','RepairRenderer')}else{@('Inspect','Apply','RepairStale','RepairRenderer','Recover')}
    if (($Request.schemaVersion -isnot [int] -and $Request.schemaVersion -isnot [long]) -or @([int]1,[int]2) -cnotcontains [int]$Request.schemaVersion -or
        $Request.action -isnot [string] -or $allowed -cnotcontains $Request.action -or
        $Request.action -cne $ExpectedAction -or -not (Test-CcodSessionCanonicalGuid $Request.transactionId) -or
        $Request.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.runtimeId) -or
        $Request.existingOnly -isnot [bool] -or $Request.restartOrdinary -isnot [bool] -or
        ($Request.timeoutMilliseconds -isnot [int] -and $Request.timeoutMilliseconds -isnot [long]) -or
        $Request.timeoutMilliseconds -lt 500 -or $Request.timeoutMilliseconds -gt 120000) {
        Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'request scalar fields are invalid' $Request
    }
    if($schema2){
        Assert-CcodSessionExactProperties $Request.ownerIdentity @('pid','creationTimeUtc') 'CCOD_REQUEST_INVALID' 'ownerIdentity'
        if(-not (Test-CcodSessionPositiveUInt64 $Request.runtimeGeneration) -or -not (Test-CcodSessionPositiveUInt64 $Request.leaseEpoch) -or
            ($Request.ownerIdentity.pid -isnot [int] -and $Request.ownerIdentity.pid -isnot [long]) -or $Request.ownerIdentity.pid -lt 1 -or $Request.ownerIdentity.pid -gt [int]::MaxValue -or
            -not (Test-CcodSessionCanonicalUtc $Request.ownerIdentity.creationTimeUtc)){
            Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'lifecycle fence fields are invalid' $Request
        }
    }
    Assert-CcodSessionExactProperties $Request.supervisorIdentity @('pid','creationTimeUtc','sessionId') 'CCOD_REQUEST_INVALID' 'supervisorIdentity'
    if (($Request.supervisorIdentity.pid -isnot [int] -and $Request.supervisorIdentity.pid -isnot [long]) -or
        $Request.supervisorIdentity.pid -lt 1 -or $Request.supervisorIdentity.pid -gt [int]::MaxValue -or
        -not (Test-CcodSessionCanonicalUtc $Request.supervisorIdentity.creationTimeUtc) -or
        $Request.supervisorIdentity.sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.supervisorIdentity.sessionId)) {
        Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'supervisorIdentity is invalid' $Request.supervisorIdentity
    }
    foreach ($name in @('rendererPort','mainPort')) {
        $value = $Request.$name
        if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 65535)) {
            Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'request port is invalid' $Request
        }
    }
    if ($null -ne $Request.source) { Assert-CcodSessionSnapshot $Request.source }
    switch ($Request.action) {
        'Inspect' {
            if ($null -ne $Request.source -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or -not $Request.restartOrdinary) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Inspect fields are inconsistent' $Request
            }
        }
        'Apply' {
            if (($null -eq $Request.source -and $Request.existingOnly) -or -not $Request.restartOrdinary -or
                ($null -ne $Request.source -and (-not $Request.source.IsTopLevel -or $Request.source.Mode -cne 'Ordinary')) -or
                ($null -ne $Request.rendererPort -and $null -ne $Request.mainPort -and $Request.rendererPort -eq $Request.mainPort)) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Apply fields are inconsistent' $Request
            }
        }
        'Close' {
            if (-not $Request.existingOnly -or $Request.restartOrdinary -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or
                ($null -ne $Request.source -and (-not $Request.source.IsTopLevel -or @('Ordinary','Special') -cnotcontains $Request.source.Mode))) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Close fields are inconsistent' $Request
            }
        }
        'RepairStale' {
            if ($null -eq $Request.source -or -not $Request.existingOnly -or -not $Request.restartOrdinary -or
                -not $Request.source.IsTopLevel -or $Request.source.Mode -cne 'Unrelated' -or
                $Request.source.RendererPort -isnot [int] -or $Request.source.MainPort -isnot [int] -or
                $Request.source.RendererPort -eq $Request.source.MainPort -or
                $null -ne $Request.rendererPort -or $null -ne $Request.mainPort) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'RepairStale fields are inconsistent' $Request
            }
        }
        'RepairRenderer' {
            if ($null -ne $Request.source -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or -not $Request.restartOrdinary) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'RepairRenderer fields are inconsistent' $Request
            }
        }
        'Recover' {
            if ($null -ne $Request.source -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Recover fields are inconsistent' $Request
            }
        }
    }
}

function Test-CcodSessionLifecycleFenceFailure($Record) {
    if($null -eq $Record){return $false}
    $code=[string]$Record.FullyQualifiedErrorId
    if($code.Contains(',')){$code=$code.Split(',')[0]}
    return $code -ceq 'CCOD_LIFECYCLE_FENCE_STALE'
}

function Assert-CcodSessionMutationFence {
    param($Request,[hashtable]$Adapter)
    if($Request.schemaVersion -ne 2){return}
    if($null -eq $Adapter -or -not $Adapter.ContainsKey('AssertLifecycleFence') -or $null -eq $Adapter.AssertLifecycleFence){
        Throw-CcodSessionError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle mutation lacks an exact fence assertion' $Request.ownerIdentity
    }
    try{[void](& $Adapter.AssertLifecycleFence $Request.runtimeGeneration $Request.leaseEpoch $Request.ownerIdentity)}catch{
        if(Test-CcodSessionLifecycleFenceFailure $_){throw}
        Throw-CcodSessionError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle fence could not be revalidated' $Request.ownerIdentity
    }
}

function Invoke-CcodSessionMutation {
    param($Request,[hashtable]$Adapter,[Parameter(Mandatory)][string]$Operation,[AllowEmptyCollection()][object[]]$Arguments=@())
    Assert-CcodSessionMutationFence $Request $Adapter
    if(-not $Adapter.ContainsKey($Operation) -or $null -eq $Adapter[$Operation]){Throw-CcodSessionError 'CCOD_SESSION_FAILED' "Mutation adapter $Operation is unavailable" $null}
    $callback=$Adapter[$Operation]
    return & $callback @Arguments
}

function Assert-CcodSessionPaths {
    param($Paths)
    Assert-CcodSessionExactProperties $Paths @('StateRoot','TransitionPath','TransitionLogPath','SessionLogPath','CheckerPath','OrchestratorPath','MainPayloadPath') 'CCOD_PATHS_INVALID' 'Paths'
    $values = [Collections.Generic.List[string]]::new()
    foreach ($name in @('StateRoot','TransitionPath','TransitionLogPath','SessionLogPath','CheckerPath','OrchestratorPath','MainPayloadPath')) {
        $value = $Paths.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value)) {
            Throw-CcodSessionError 'CCOD_PATHS_INVALID' "Paths.$name must be absolute" $Paths
        }
        $canonical = [IO.Path]::GetFullPath($value)
        if ($canonical -cne $value -or $values -contains $canonical.ToLowerInvariant()) {
            Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Paths must be canonical and non-colliding' $Paths
        }
        $cursor=if([IO.File]::Exists($canonical) -or [IO.Directory]::Exists($canonical)){$canonical}else{Split-Path -Parent $canonical}
        while(-not [string]::IsNullOrWhiteSpace($cursor)){
            if([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)){
                $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Paths may not traverse reparse points' $cursor}
            }
            $parent=Split-Path -Parent $cursor;if($parent -ceq $cursor){break};$cursor=$parent
        }
        $values.Add($canonical.ToLowerInvariant())
    }
    $expectedTransition = [IO.Path]::GetFullPath((Join-Path $Paths.StateRoot 'transition.json'))
    if ($Paths.TransitionPath -cne $expectedTransition) { Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'TransitionPath must be StateRoot\transition.json' $Paths }
    $stateParent = Split-Path -Parent $Paths.StateRoot
    foreach ($name in @('TransitionLogPath','SessionLogPath')) {
        if (-not $Paths.$name.StartsWith($stateParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Persistent paths must share the installed stable root' $Paths
        }
    }
    $runtimeRoot=Split-Path (Split-Path $Paths.CheckerPath -Parent) -Parent
    $expectedChecker=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\check-package.mjs'))
    $expectedOrchestrator=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\orchestrator.js'))
    $expectedPayload=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\main-payload.js'))
    if(-not $runtimeRoot.StartsWith($stateParent+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $Paths.CheckerPath -cne $expectedChecker -or $Paths.OrchestratorPath -cne $expectedOrchestrator -or $Paths.MainPayloadPath -cne $expectedPayload){
        Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Runtime payload paths must be exact children of one verified runtime root' $Paths
    }
}

function New-CcodSessionResult {
    param([string]$Action, $TransactionId)
    [pscustomobject][ordered]@{
        schemaVersion=1; action=$Action; ok=$false; outcome='Error'; safeState='Error'; stage='InputValidation'
        transactionId=$TransactionId; package=$null; source=$null; special=$null; probes=$null; recovery=$null; error=$null; logFile=$null
    }
}

function Get-CcodSessionErrorCode($Record) {
    $code = [string]$Record.FullyQualifiedErrorId
    if ($code.Contains(',')) { $code = $code.Split(',')[0] }
    if ([string]::IsNullOrWhiteSpace($code) -or $script:CcodSessionStableErrorCodes -cnotcontains $code) { return 'CCOD_SESSION_FAILED' }
    return $code
}

function Set-CcodSessionFailure($Result, $Record, [string]$Stage) {
    $Result.ok=$false; $Result.outcome='Error'; $Result.safeState='Error'; $Result.stage=$Stage
    $Result.error=[pscustomobject][ordered]@{ code=(Get-CcodSessionErrorCode $Record); stage=$Stage; message='The session operation failed safely. See the session log for details.' }
    return $Result
}

function Write-CcodSessionDiagnostic {
    param($Result,[string]$Action,[string]$TransactionId,[string]$Stage,[string]$Code,$Paths,[hashtable]$Adapter)
    if($null -eq $Paths -or $null -eq $Adapter -or $null -eq $Adapter.WriteLog){return}
    $record=[pscustomobject][ordered]@{schemaVersion=1;timestampUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);action=$Action;transactionId=$TransactionId;stage=$Stage;code=$Code}
    try{& $Adapter.WriteLog $Paths.SessionLogPath ($record|ConvertTo-Json -Depth 4 -Compress)|Out-Null;$Result.logFile=$Paths.SessionLogPath}catch{}
}

function ConvertTo-CcodManagedArgument {
    param([Parameter(Mandatory)][string]$Argument)
    $quoted=[Text.StringBuilder]::new();[void]$quoted.Append('"');$backslashes=0
    foreach($character in $Argument.ToCharArray()){
        if($character -eq [char]'\'){$backslashes++;continue}
        if($character -eq [char]'"'){[void]$quoted.Append(('\' * (($backslashes*2)+1)));[void]$quoted.Append('"');$backslashes=0;continue}
        if($backslashes -gt 0){[void]$quoted.Append(('\' * $backslashes));$backslashes=0}
        [void]$quoted.Append($character)
    }
    if($backslashes -gt 0){[void]$quoted.Append(('\' * ($backslashes*2)))}
    [void]$quoted.Append('"');return $quoted.ToString()
}

function Invoke-CcodManagedNode {
    param([Parameter(Mandatory)][string]$NodePath,[Parameter(Mandatory)][string[]]$Arguments)
    $startInfo=[Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName=$NodePath
    $startInfo.Arguments=(($Arguments | ForEach-Object { ConvertTo-CcodManagedArgument -Argument $_ }) -join ' ')
    $startInfo.UseShellExecute=$false
    $startInfo.CreateNoWindow=$true
    $startInfo.RedirectStandardOutput=$true
    $startInfo.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new()
    $result=$null
    try{
        $process.StartInfo=$startInfo
        if(-not $process.Start()){throw 'Could not start Node.js.'}
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result=[pscustomobject][ordered]@{ExitCode=$process.ExitCode;Stdout=$stdoutTask.Result;Stderr=$stderrTask.Result}
    }catch{
        $result=[pscustomobject][ordered]@{ExitCode=-1;Stdout='';Stderr=("MANAGED_NODE_EXCEPTION $($_.Exception.GetType().FullName): $($_.Exception.Message)")}
    }finally{
        $process.Dispose()
    }
    return $result
}

function ConvertTo-CcodSessionPackage($Probe) {
    if ($null -eq $Probe) { return $null }
    [pscustomobject][ordered]@{ fullName=$Probe.PackageFullName; familyName=$Probe.PackageFamilyName; version=$Probe.PackageVersion; appAsarSha256=$Probe.AppAsarSha256 }
}

function ConvertTo-CcodSessionSource($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    [pscustomobject][ordered]@{ pid=[int]$Snapshot.Pid; creationTimeUtc=$Snapshot.CreationTimeUtc }
}

function ConvertTo-CcodSessionSpecial($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    [pscustomobject][ordered]@{ pid=[int]$Snapshot.Pid; creationTimeUtc=$Snapshot.CreationTimeUtc; rendererPort=$Snapshot.RendererPort; mainPort=$Snapshot.MainPort }
}

function ConvertTo-CcodPublicBridgeProbes {
    param($Bridge,[ValidateSet('Full','Renderer')][string]$Mode)
    $renderer=[pscustomobject][ordered]@{targetUrl=$Bridge.renderer.targetUrl;currentDocument=[pscustomobject][ordered]@{installed=[bool]$Bridge.renderer.currentDocument.installed};newDocumentScriptInstalled=[bool]$Bridge.renderer.newDocumentScriptInstalled;probe=[pscustomobject][ordered]@{proof=[bool]$Bridge.renderer.probe.proof;targetGate=$Bridge.renderer.probe.targetGate}}
    if($Mode -ceq 'Renderer'){return [pscustomobject][ordered]@{renderer=$renderer}}
    $main=[pscustomobject][ordered]@{inspectorPortClosed=[pscustomobject][ordered]@{confirmed=[bool]$Bridge.main.inspectorPortClosed.confirmed;code=$Bridge.main.inspectorPortClosed.code}}
    return [pscustomobject][ordered]@{main=$main;renderer=$renderer}
}

function Invoke-CcodSessionBridge {
    param(
        $Request,
        [ValidateSet('Full','Renderer','Probe')][string]$Mode,
        [string]$NodePath,
        $Paths,
        [int]$RendererPort,
        [AllowNull()][Nullable[int]]$MainPort,
        [int]$TimeoutMilliseconds,
        [hashtable]$Adapter
    )
    $arguments=if($Mode -ceq 'Probe'){
        @($Paths.OrchestratorPath,'--mode','probe','--renderer-port',[string]$RendererPort,'--main-port',[string]$MainPort,'--timeout-ms',[string]$TimeoutMilliseconds)
    }else{
        @($Paths.OrchestratorPath,'--mode',$Mode.ToLowerInvariant(),'--renderer-port',[string]$RendererPort,'--timeout-ms',[string]$TimeoutMilliseconds)
    }
    if($Mode -ceq 'Full'){
        $arguments+=@('--main-port',[string]$MainPort,'--main-payload',$Paths.MainPayloadPath)
    }
    if($Mode -ceq 'Probe'){$invocation=& $Adapter.InvokeNode $NodePath $arguments}
    else{$invocation=Invoke-CcodSessionMutation $Request $Adapter 'InvokeNode' @($NodePath,@($arguments))}
    return Test-CcodBridgeResult -Mode $Mode -Invocation $invocation
}

function Test-CcodReplaySpecialRoot {
    param($Snapshot,$Transition,$Probe,$Request,[hashtable]$Adapter,[switch]$RequireRecordedIdentity)
    if($null -eq $Snapshot){return $false}
    $identity=& $Adapter.CurrentIdentity
    if(-not $Snapshot.IsTopLevel -or [string]$Snapshot.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
        [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $Snapshot.UserSid -cne $identity.UserSid -or
        -not $Snapshot.Path.Equals($Probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $Snapshot.PackageFamilyName -cne $Probe.PackageFamilyName -or
        $Snapshot.RendererPort -ne $Transition.rendererPort -or $Snapshot.MainPort -ne $Transition.mainPort){return $false}
    if($RequireRecordedIdentity -and ($Snapshot.Pid -ne $Transition.specialPid -or $Snapshot.CreationTimeUtc -cne $Transition.specialCreationTimeUtc)){return $false}
    if(-not $RequireRecordedIdentity -and [DateTime]::Parse($Snapshot.CreationTimeUtc).ToUniversalTime() -lt [DateTime]::Parse($Transition.createdAtUtc).ToUniversalTime()){return $false}
    return $true
}

function Get-CcodStageAwareSpecialObservation {
    param($Transition,$State,$Probe,$Request,$Paths,[hashtable]$Adapter)
    $candidate=$null;$outcome='NoCandidate';$conflicts=@();$validation='Indeterminate';$bridge=$null;$mode=$null
    if($Transition.stage -ceq 'SpecialLaunchRequested'){
        $raw=& $Adapter.ObserveSpecial $Transition $Paths $Request.timeoutMilliseconds
        $outcome=$raw.Outcome;$conflicts=@($raw.ConflictOwners);$candidates=@($raw.Candidates)
        if($candidates.Count -eq 0 -and $null -ne $raw.Snapshot){$candidates=@($raw.Snapshot)}
        if($outcome -ceq 'Confirmed' -and $candidates.Count -eq 1 -and $conflicts.Count -eq 0){$candidate=$candidates[0]}
        if($null -ne $candidate -and (Test-CcodReplaySpecialRoot $candidate $Transition $Probe $Request $Adapter)){
            $mode='Full'
            try{$bridge=Invoke-CcodSessionBridge -Request $Request -Mode Full -NodePath $Probe.NodePath -Paths $Paths -RendererPort $Transition.rendererPort -MainPort $Transition.mainPort -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $Adapter;$validation='Valid'}catch{if(Test-CcodSessionLifecycleFenceFailure $_){throw};$validation='Invalid'}
        }elseif($null -ne $candidate){$validation='Invalid'}
    } else {
        $candidate=& $Adapter.GetProcess $Transition.specialPid $State.Status
        if($null -ne $candidate){$outcome='Confirmed'}
        if($null -ne $candidate -and (Test-CcodReplaySpecialRoot $candidate $Transition $Probe $Request $Adapter -RequireRecordedIdentity)){
            $mainClosed=& $Adapter.WaitPortClosed $Transition.mainPort (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds)
            if($Transition.stage -ceq 'SpecialStarted' -and -not $mainClosed){$mode='Full'}elseif($mainClosed){$mode='Renderer'}
            if($null -ne $mode){
                try{$bridge=Invoke-CcodSessionBridge -Request $Request -Mode $mode -NodePath $Probe.NodePath -Paths $Paths -RendererPort $Transition.rendererPort -MainPort $(if($mode -ceq 'Full'){$Transition.mainPort}else{$null}) -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $Adapter;$validation='Valid'}catch{if(Test-CcodSessionLifecycleFenceFailure $_){throw};$validation='Invalid'}
            }else{$validation='Invalid'}
        }elseif($null -ne $candidate){$validation='Invalid'}
    }
    return [pscustomobject]@{Outcome=$outcome;Snapshot=$candidate;Candidates=if($null -eq $candidate){@()}else{@($candidate)};ConflictOwners=@($conflicts);Validation=$validation;Bridge=$bridge;BridgeMode=$mode}
}

function Complete-CcodActivatedReplay {
    param($Result,$Request,$Paths,[hashtable]$Adapter,$Probe,$Special,$Bridge,[string]$JournalTransactionId)
    $status=[pscustomobject][ordered]@{schemaVersion=1;session=[pscustomobject][ordered]@{supervisorPid=[int]$Request.supervisorIdentity.pid;supervisorCreationTimeUtc=$Request.supervisorIdentity.creationTimeUtc;sessionId=$Request.supervisorIdentity.sessionId;runtimeId=$Request.runtimeId;sessionState='Active';codex=[pscustomobject][ordered]@{pid=[int]$Special.Pid;creationTimeUtc=$Special.CreationTimeUtc;packageFullName=$Probe.PackageFullName;packageVersion=$Probe.PackageVersion;appAsarSha256=$Probe.AppAsarSha256;mainPort=[int]$Special.MainPort;rendererPort=[int]$Special.RendererPort;mainProbe='Closed';rendererProbe='BridgeValid'}}}
    $live=[pscustomobject][ordered]@{Valid=$true;runtimeId=$Request.runtimeId;pid=[int]$Special.Pid;creationTimeUtc=$Special.CreationTimeUtc;packageFullName=$Probe.PackageFullName;packageVersion=$Probe.PackageVersion;appAsarSha256=$Probe.AppAsarSha256;mainPort=[int]$Special.MainPort;rendererPort=[int]$Special.RendererPort;mainProbe='Closed';rendererProbe='BridgeValid'}
    Invoke-CcodSessionMutation $Request $Adapter 'WriteStatus' @($Paths.StateRoot,$status,$live)|Out-Null
    $verified=& $Adapter.ReadVerified $Paths.StateRoot;$succeeded=New-CcodVerifiedStoreWithRecord $verified $Probe $Request.runtimeId 'Succeeded' 'Valid' (& $Adapter.UtcNow);Invoke-CcodSessionMutation $Request $Adapter 'WriteVerified' @($Paths.StateRoot,$succeeded)|Out-Null
    Invoke-CcodSessionMutation $Request $Adapter 'CompleteTransition' @($Paths.TransitionPath,$Paths.TransitionLogPath,$JournalTransactionId,'Activated')|Out-Null
    $Result.special=ConvertTo-CcodSessionSpecial $Special
    if($null -ne $Bridge){$mode=if($null -ne $Bridge.PSObject.Properties['main']){'Full'}else{'Renderer'};$Result.probes=ConvertTo-CcodPublicBridgeProbes $Bridge $mode}
    $Result.ok=$true;$Result.outcome='NoAction';$Result.safeState='SpecialValidated';$Result.stage='Activated';return $Result
}

function Complete-CcodRecoveredReplay {
    param($Result,$Request,$Paths,[hashtable]$Adapter,$Probe,$Ordinary,[string]$JournalTransactionId)
    Invoke-CcodSessionMutation $Request $Adapter 'WriteStatus' @($Paths.StateRoot,([pscustomobject][ordered]@{schemaVersion=1;session=$null}),$null)|Out-Null
    $store=& $Adapter.ReadVerified $Paths.StateRoot;$failed=New-CcodVerifiedStoreWithRecord $store $Probe $Request.runtimeId 'Failed' 'NotRun' (& $Adapter.UtcNow);Invoke-CcodSessionMutation $Request $Adapter 'WriteVerified' @($Paths.StateRoot,$failed)|Out-Null
    Invoke-CcodSessionMutation $Request $Adapter 'CompleteTransition' @($Paths.TransitionPath,$Paths.TransitionLogPath,$JournalTransactionId,'Recovered')|Out-Null
    $ignore=Get-CcodRecoveryIgnoreKey -Pid $Ordinary.Pid -CreationTimeUtc $Ordinary.CreationTimeUtc -TransactionId $JournalTransactionId
    $suppression=Get-CcodSuppressionKey -PackageFullName $Probe.PackageFullName -AppAsarSha256 $Probe.AppAsarSha256 -RuntimeId $Request.runtimeId
    $Result.source=ConvertTo-CcodSessionSource $Ordinary;$Result.special=$null
    $Result.recovery=[pscustomobject][ordered]@{pid=[int]$Ordinary.Pid;creationTimeUtc=$Ordinary.CreationTimeUtc;ignoreKey=$ignore;suppressionKey=$suppression;portsClosed=$true;disposition='ReplayAdopted';priorTransactionId=$JournalTransactionId}
    $Result.ok=$true;$Result.outcome='Recovered';$Result.safeState='OrdinaryRunning';$Result.stage='Recovered';return $Result
}

function ConvertTo-CcodJournalPackage($Probe) {
    [pscustomobject][ordered]@{
        FullName=$Probe.PackageFullName; FamilyName=$Probe.PackageFamilyName; Version=$Probe.PackageVersion
        InstallLocation='Unavailable'; ExecutablePath=$Probe.ExecutablePath; AppAsarPath='Unavailable'; NativeDirectory='Unavailable'
        AppAsarSha256=$Probe.AppAsarSha256; StaticClassification=$Probe.StaticClassification; SignatureState='Valid'; NodePath=$Probe.NodePath
    }
}

function New-CcodVerifiedStoreWithRecord {
    param($Store,$Probe,[string]$RuntimeId,[ValidateSet('Succeeded','Failed')][string]$Outcome,[ValidateSet('Valid','Invalid','NotRun')][string]$ProbeState,[datetime]$UtcNow)
    $packages=[ordered]@{}
    if($null -ne $Store -and $null -ne $Store.packages){
        foreach($property in $Store.packages.PSObject.Properties){$packages[$property.Name]=$property.Value}
        if($Store.packages -is [Collections.IDictionary]){foreach($key in $Store.packages.Keys){$packages[$key]=$Store.packages[$key]}}
    }
    $key=Get-CcodSuppressionKey -PackageFullName $Probe.PackageFullName -AppAsarSha256 $Probe.AppAsarSha256 -RuntimeId $RuntimeId
    $packages[$key]=[pscustomobject][ordered]@{
        packageFullName=$Probe.PackageFullName;packageVersion=$Probe.PackageVersion;appAsarSha256=$Probe.AppAsarSha256;runtimeId=$RuntimeId
        staticClassification=$Probe.StaticClassification;dynamicOutcome=$Outcome;probeState=$ProbeState
        confirmedAtUtc=$UtcNow.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
    return [pscustomobject][ordered]@{schemaVersion=1;packages=[pscustomobject]$packages}
}

function Get-CcodTreeDepth {
    param($Snapshot,[hashtable]$ByPid)
    $depth=0;$seen=@{};$cursor=$Snapshot
    while($null -ne $cursor.ParentPid -and $ByPid.ContainsKey([int]$cursor.ParentPid) -and -not $seen.ContainsKey([int]$cursor.ParentPid)){
        $seen[[int]$cursor.ParentPid]=$true;$depth++;$cursor=$ByPid[[int]$cursor.ParentPid]
    }
    return $depth
}

function Get-CcodChildFirstVerifiedTree {
    param($Root,$StatusEvidence,[hashtable]$Adapter)
    $tree=@(& $Adapter.GetTree $Root $StatusEvidence)
    if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recorded special tree could not be verified' $Root}
    $byPid=@{};foreach($member in $tree){$byPid[[int]$member.Pid]=$member}
    if(-not $byPid.ContainsKey([int]$Root.Pid)){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Verified tree omitted the recorded root' $Root}
    return @($tree|Sort-Object @{Expression={-(Get-CcodTreeDepth $_ $byPid)}},@{Expression={$_.Pid}})
}

function Get-CcodProcessControlTimeout([int]$TimeoutMilliseconds) {
    return [Math]::Min(60000,$TimeoutMilliseconds)
}

function Get-CcodCurrentPackageRoots {
    param($StatusEvidence,$Probe,$Request,[hashtable]$Adapter)
    $identity=& $Adapter.CurrentIdentity
    if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]::IsNullOrWhiteSpace([string]$identity.UserSid)){
        Throw-CcodSessionError 'CCOD_SOURCE_AMBIGUOUS' 'The request supervisor does not match the current Windows session identity' $Request.supervisorIdentity
    }
    return @(& $Adapter.ListProcesses $StatusEvidence|Where-Object{
        $_.IsTopLevel -and
        [string]$_.SessionId -ceq [string]$Request.supervisorIdentity.sessionId -and
        $_.UserSid -ceq $identity.UserSid -and
        $_.Path.Equals($Probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -and
        $_.PackageFamilyName -ceq $Probe.PackageFamilyName
    }|Sort-Object CreationTimeUtc,Pid)
}

function ConvertTo-CcodSessionStaleSource($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    [pscustomobject][ordered]@{
        pid=[int]$Snapshot.Pid;creationTimeUtc=[string]$Snapshot.CreationTimeUtc;sessionId=[int]$Snapshot.SessionId;userSid=[string]$Snapshot.UserSid
        path=[string]$Snapshot.Path;packageFamilyName=[string]$Snapshot.PackageFamilyName;commandLine=[string]$Snapshot.CommandLine;parentPid=$Snapshot.ParentPid
        isTopLevel=[bool]$Snapshot.IsTopLevel;mode=[string]$Snapshot.Mode;rendererPort=[int]$Snapshot.RendererPort;mainPort=[int]$Snapshot.MainPort
    }
}

function Assert-CcodLiveSupervisorIdentity {
    param($Request,[hashtable]$Adapter)
    $identity=& $Adapter.CurrentIdentity
    $live=& $Adapter.GetSupervisorProcess ([int]$Request.supervisorIdentity.pid)
    if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
       [string]::IsNullOrWhiteSpace([string]$identity.UserSid) -or $null -eq $live -or
       $live.Pid -isnot [int] -or $live.Pid -ne [int]$Request.supervisorIdentity.pid -or
       $live.CreationTimeUtc -isnot [string] -or $live.CreationTimeUtc -cne $Request.supervisorIdentity.creationTimeUtc -or
       [string]$live.SessionId -cne [string]$Request.supervisorIdentity.sessionId){
        Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Repair authority no longer matches the live supervisor lifecycle' $Request.supervisorIdentity
    }
    return $identity
}

function Find-CcodOrdinarySnapshot {
    param($StatusEvidence,[hashtable]$Adapter)
    $candidates=@(& $Adapter.ListProcesses $StatusEvidence|Where-Object{$_.IsTopLevel -and $_.Mode -ceq 'Ordinary'}|Sort-Object CreationTimeUtc,Pid)
    if($candidates.Count -gt 0){return $candidates[0]}
    return $null
}

function Wait-CcodOrdinarySnapshot {
    param($StatusEvidence,[hashtable]$Adapter)
    for($index=0;$index -lt 5;$index++){
        $candidate=Find-CcodOrdinarySnapshot $StatusEvidence $Adapter;if($null -ne $candidate){return $candidate}
        & $Adapter.Delay 1000
    }
    return Find-CcodOrdinarySnapshot $StatusEvidence $Adapter
}

function Invoke-CcodRecoveryOperation {
    param($Result,$Request,$Paths,[hashtable]$Adapter,$State,$Probe,[string]$CurrentStage,$Special,$RendererPort,$MainPort,[string]$PriorTransactionId)
    $Result.stage='Recovery';$processTimeout=Get-CcodProcessControlTimeout $Request.timeoutMilliseconds
    if($null -ne $Special){
        $tree=Get-CcodChildFirstVerifiedTree $Special $State.Status $Adapter
        foreach($member in $tree){
            $current=& $Adapter.GetProcess $member.Pid $State.Status
            if($null -eq $current){continue}
            if(-not (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Verified tree identity changed before stop' $member}
            $receipt=Invoke-CcodSessionMutation $Request $Adapter 'StopProcess' @($member,$State.Status,$processTimeout)
            if($receipt.Outcome -cne 'Stopped' -and $receipt.Outcome -cne 'SourceExited'){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'A verified tree member did not stop safely' $member}
        }
    }
    $portsClosed=$true
    if($null -ne $RendererPort -and $null -ne $MainPort){
        foreach($port in @($RendererPort,$MainPort)){if(-not (& $Adapter.WaitPortClosed $port $processTimeout)){$portsClosed=$false}}
    }
    if(-not $portsClosed){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recorded debug ports did not explicitly refuse' $Special}
    if($CurrentStage -cne 'RecoveryLaunchRequested'){
        $transition=Invoke-CcodSessionMutation $Request $Adapter 'SetTransition' @($Paths.TransitionPath,$PriorTransactionId,$CurrentStage,'RecoveryLaunchRequested',$null,$null,$null,$null)
    }
    $ordinary=Wait-CcodOrdinarySnapshot $State.Status $Adapter;$disposition='AdoptedDuringObservation'
    if($null -eq $ordinary){
        $start=Invoke-CcodSessionMutation $Request $Adapter 'StartOrdinary' @($processTimeout)
        $disposition='LaunchedOnce'
        if($null -ne $start.Snapshot){$ordinary=$start.Snapshot}else{$ordinary=Wait-CcodOrdinarySnapshot $State.Status $Adapter}
    }
    if($null -eq $ordinary -or $ordinary.Mode -cne 'Ordinary' -or -not $ordinary.IsTopLevel){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Ordinary recovery identity was not proven' $ordinary}
    $transition=Invoke-CcodSessionMutation $Request $Adapter 'SetTransition' @($Paths.TransitionPath,$PriorTransactionId,'RecoveryLaunchRequested','Recovered',$null,$ordinary,$null,$null)
    $store=& $Adapter.ReadVerified $Paths.StateRoot
    $failed=New-CcodVerifiedStoreWithRecord $store $Probe $Request.runtimeId 'Failed' 'NotRun' (& $Adapter.UtcNow)
    Invoke-CcodSessionMutation $Request $Adapter 'WriteVerified' @($Paths.StateRoot,$failed)|Out-Null
    Invoke-CcodSessionMutation $Request $Adapter 'WriteStatus' @($Paths.StateRoot,([pscustomobject][ordered]@{schemaVersion=1;session=$null}),$null)|Out-Null
    Invoke-CcodSessionMutation $Request $Adapter 'CompleteTransition' @($Paths.TransitionPath,$Paths.TransitionLogPath,$PriorTransactionId,'Recovered')|Out-Null
    $ignore=Get-CcodRecoveryIgnoreKey -Pid $ordinary.Pid -CreationTimeUtc $ordinary.CreationTimeUtc -TransactionId $PriorTransactionId
    $suppression=Get-CcodSuppressionKey -PackageFullName $Probe.PackageFullName -AppAsarSha256 $Probe.AppAsarSha256 -RuntimeId $Request.runtimeId
    $Result.source=ConvertTo-CcodSessionSource $ordinary
    $Result.recovery=[pscustomobject][ordered]@{pid=[int]$ordinary.Pid;creationTimeUtc=$ordinary.CreationTimeUtc;ignoreKey=$ignore;suppressionKey=$suppression;portsClosed=$portsClosed;disposition=$disposition;priorTransactionId=$PriorTransactionId}
    $Result.ok=$true;$Result.outcome='Recovered';$Result.safeState='OrdinaryRunning';$Result.stage='Recovered';$Result.special=$null
    return $Result
}

function Invoke-CcodCloseVerifiedTree {
    param($Request,[object[]]$Tree,$StatusEvidence,[hashtable]$Adapter,[int]$TimeoutMilliseconds,$RendererPort,$MainPort)
    if($Tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close target tree was not verified' $null}
    $processTimeout=Get-CcodProcessControlTimeout $TimeoutMilliseconds
    $byPid=@{};foreach($member in $Tree){$byPid[[int]$member.Pid]=$member}
    $ordered=@($Tree|Sort-Object @{Expression={-(Get-CcodTreeDepth $_ $byPid)}},@{Expression={$_.Pid}})
    foreach($member in $ordered){
        $current=& $Adapter.GetProcess $member.Pid $StatusEvidence
        if($null -eq $current){continue}
        if(-not (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree identity changed before stop' $member}
        $receipt=Invoke-CcodSessionMutation $Request $Adapter 'StopProcess' @($member,$StatusEvidence,$processTimeout)
        if($receipt.Outcome -cne 'Stopped' -and $receipt.Outcome -cne 'SourceExited'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree member did not stop safely' $member}
    }
    foreach($member in $Tree){
        $current=& $Adapter.GetProcess $member.Pid $StatusEvidence
        if($null -ne $current -and (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree member remains alive after stop' $member}
    }
    if($null -ne $RendererPort -and $null -ne $MainPort){
        foreach($port in @($RendererPort,$MainPort)){if(-not (& $Adapter.WaitPortClosed $port $processTimeout)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'A recorded close port did not explicitly refuse' $port}}
    }
}

function Complete-CcodCloseResult {
    param($Result,$Request,$Paths,[hashtable]$Adapter,[string]$JournalTransactionId)
    Invoke-CcodSessionMutation $Request $Adapter 'WriteStatus' @($Paths.StateRoot,([pscustomobject][ordered]@{schemaVersion=1;session=$null}),$null)|Out-Null
    Invoke-CcodSessionMutation $Request $Adapter 'CompleteTransition' @($Paths.TransitionPath,$Paths.TransitionLogPath,$JournalTransactionId,'Closed')|Out-Null
    $Result.ok=$true;$Result.outcome='Closed';$Result.safeState='Closed';$Result.stage='Closed';$Result.special=$null
    return $Result
}

function Get-CcodStrictProcessIdentityObservation {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedCreationTimeUtc,
        [Parameter(Mandatory)][hashtable]$Adapter
    )

    try { $output=@(& $Adapter.ObserveProcessIdentity $ProcessId $ExpectedCreationTimeUtc 2>&1) } catch {
        Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active process identity could not be observed strictly' $ProcessId
    }
    if($output.Count -ne 1 -or $output[0] -is [Management.Automation.ErrorRecord]){
        Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active process identity observation was malformed' $output
    }
    $identity=$output[0]
    Assert-CcodSessionExactProperties $identity @('Outcome','Pid','CreationTimeUtc') 'CCOD_CLOSE_UNPROVEN' 'process identity observation'
    if($identity.Outcome -isnot [string] -or @('Absent','SameIdentity','IdentityChanged') -cnotcontains $identity.Outcome -or
       $identity.Pid -isnot [int] -or $identity.Pid -ne $ProcessId){
        Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active process identity observation was invalid' $identity
    }
    switch -CaseSensitive ($identity.Outcome) {
        'Absent' {
            if($null -ne $identity.CreationTimeUtc){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Absent identity observation carried a creation time' $identity}
        }
        'SameIdentity' {
            if($identity.CreationTimeUtc -isnot [string] -or $identity.CreationTimeUtc -cne $ExpectedCreationTimeUtc){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Same identity observation did not match the recorded creation time' $identity}
        }
        'IdentityChanged' {
            if(-not (Test-CcodSessionCanonicalUtc $identity.CreationTimeUtc) -or $identity.CreationTimeUtc -ceq $ExpectedCreationTimeUtc){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Changed identity observation lacked a distinct canonical creation time' $identity}
        }
    }
    return $identity
}

function Merge-CcodSessionAdapters($Adapters) {
    $defaults = @{
        ReadState={ param($StateRoot,$SuppressionKey) Read-CcodState -StateRoot $StateRoot -CurrentSuppressionKey $SuppressionKey }
        GetPackageIdentity={ Get-CcodPackageIdentity }
        StaticProbe={ param($NodeCandidates,$CheckerPath) Invoke-CcodStaticProbe -NodeCandidates $NodeCandidates -CheckerPath $CheckerPath }
        ListProcesses={ param($StatusEvidence)
            $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=$current.SessionId}finally{$current.Dispose()}
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            $snapshots=[Collections.Generic.List[object]]::new()
            foreach($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)){
                $snapshot=Get-CcodProcessSnapshot -ProcessId $process.Id -StatusEvidence $StatusEvidence
                if($null -ne $snapshot -and $snapshot.SessionId -eq $sessionId -and $snapshot.UserSid -ceq $sid){$snapshots.Add($snapshot)}
            }
            return $snapshots.ToArray()
        }
        GetProcess={ param($ProcessId,$StatusEvidence) Get-CcodProcessSnapshot -ProcessId $ProcessId -StatusEvidence $StatusEvidence }
        ObserveProcessIdentity={ param($ProcessId,$ExpectedCreationTimeUtc) Get-CcodProcessIdentityObservation -ProcessId $ProcessId -ExpectedCreationTimeUtc $ExpectedCreationTimeUtc }
        ProcessMatch={ param($Expected,$Actual) Test-CcodProcessMatch -Expected $Expected -Actual $Actual }
        NewTransition={ param($Path,$Source,$Package,$RuntimeId,$RendererPort,$MainPort,$TransactionId) New-CcodTransition -Path $Path -Source $Source -Package $Package -RuntimeId $RuntimeId -RendererPort $RendererPort -MainPort $MainPort -TransactionId $TransactionId }
        SetTransition={ param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)
            $parameters=@{Path=$Path;TransactionId=$TransactionId;ExpectedStage=$ExpectedStage;NewStage=$NewStage}
            if($null -ne $SpecialIdentity){$parameters.SpecialIdentity=$SpecialIdentity}; if($null -ne $RecoveryIdentity){$parameters.RecoveryIdentity=$RecoveryIdentity}
            if($null -ne $RendererPort){$parameters.RendererPort=$RendererPort}; if($null -ne $MainPort){$parameters.MainPort=$MainPort}; Set-CcodTransitionStage @parameters }
        CompleteTransition={ param($Path,$LogPath,$TransactionId,$Disposition) Complete-CcodTransition -Path $Path -LogPath $LogPath -TransactionId $TransactionId -Disposition $Disposition }
        ClearCommittedTransition={ param($Path,$LogPath,$TransactionId,$Disposition) Complete-CcodTransition -Path $Path -LogPath $LogPath -TransactionId $TransactionId -Disposition $Disposition -RequireTerminalReceipt }
        StopProcess={ param($Expected,$StatusEvidence,$TimeoutMilliseconds) Stop-CcodProcessIfMatch -Expected $Expected -StatusEvidence $StatusEvidence -TimeoutMilliseconds $TimeoutMilliseconds }
        RequestGracefulClose={ param($Expected,$StatusEvidence) Request-CcodProcessGracefulCloseIfMatch -Expected $Expected -StatusEvidence $StatusEvidence }
        WaitProcessExit={ param($Expected,$StatusEvidence,$TimeoutMilliseconds) Wait-CcodProcessExitIfMatch -Expected $Expected -StatusEvidence $StatusEvidence -TimeoutMilliseconds $TimeoutMilliseconds }
        FindStalePackageRoot={param($Package,$StatusEvidence)Get-CcodStalePackageRootResult -Package $Package}
        GetStaleTree={param($Root,$Package) Get-CcodVerifiedStaleProcessTree -Root $Root -Package $Package}
        GetStaleProcess={param($ProcessId,$Package) Get-CcodStalePackageProcessSnapshot -ProcessId $ProcessId -Package $Package -Adapter @{} }
        StopStaleProcess={param($Expected,$Package,$TimeoutMilliseconds) Stop-CcodStaleProcessIfMatch -Expected $Expected -Package $Package -TimeoutMilliseconds $TimeoutMilliseconds}
        RequestStaleGracefulClose={param($Expected,$Package) Request-CcodStaleProcessGracefulCloseIfMatch -Expected $Expected -Package $Package}
        WaitStaleProcessExit={param($Expected,$Package,$TimeoutMilliseconds) Wait-CcodStaleProcessExitIfMatch -Expected $Expected -Package $Package -TimeoutMilliseconds $TimeoutMilliseconds}
        GetPreferredRendererPort={ param($Excluded) Get-CcodRendererPreferredPort -ExcludedPorts $Excluded }
        GetPort={ param($Excluded) Get-CcodAvailableLoopbackPort -ExcludedPorts $Excluded }
        StartSpecial={ param($RendererPort,$MainPort,$TimeoutMilliseconds) Start-CcodProcess -Mode Special -RendererPort $RendererPort -MainPort $MainPort -StartupTimeoutMilliseconds $TimeoutMilliseconds }
        InvokeNode={ param($NodePath,$Arguments) Invoke-CcodManagedNode -NodePath $NodePath -Arguments @($Arguments) }
        WriteStatus={ param($StateRoot,$Status,$LiveProbe) Write-CcodStatus -StateRoot $StateRoot -Status $Status -LiveProbeResult $LiveProbe }
        ReadVerified={ param($StateRoot) Read-CcodVerifiedPackages -StateRoot $StateRoot }
        WriteVerified={ param($StateRoot,$Verified) Write-CcodVerifiedPackages -StateRoot $StateRoot -VerifiedPackages $Verified }
        UtcNow={ [DateTime]::UtcNow }
        GetTree={ param($Root,$StatusEvidence) Get-CcodVerifiedProcessTree -Root $Root -StatusEvidence $StatusEvidence }
        WaitPortClosed={ param($Port,$TimeoutMilliseconds) Wait-CcodPortClosed -Port $Port -TimeoutMilliseconds $TimeoutMilliseconds }
        StartOrdinary={ param($TimeoutMilliseconds) Start-CcodProcess -Mode Ordinary -StartupTimeoutMilliseconds $TimeoutMilliseconds }
        Delay={ param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        WriteLog={ param($Path,$Message) Write-CcodRotatingLog -Path $Path -Message $Message }
        ObserveSpecial={ param($Transition,$Paths,$TimeoutMilliseconds)
            if($null -eq $Transition.mainPort){return [pscustomobject]@{Outcome='NoCandidate';Snapshot=$null;Candidates=@();ConflictOwners=@();Validation='Indeterminate'}}
            $observation=Get-CcodTransactionProcessResult -RendererPort $Transition.rendererPort -MainPort $Transition.mainPort -TransactionTimeUtc $Transition.createdAtUtc
            $validation=if($null -ne $observation.Snapshot -and $observation.Snapshot.Mode -ceq 'Special'){'Valid'}else{'Indeterminate'}
            return [pscustomobject]@{Outcome=$observation.Outcome;Snapshot=$observation.Snapshot;Candidates=@($observation.Candidates);ConflictOwners=@($observation.ConflictOwners);Validation=$validation}
        }
        ObserveSpecialIsDefault=$true
        CurrentIdentity={
            $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=[string]$current.SessionId}finally{$current.Dispose()}
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            [pscustomobject][ordered]@{SessionId=$sessionId;UserSid=$sid}
        }
        GetSupervisorProcess={param($ProcessId)
            $process=$null
            try{
                $process=[Diagnostics.Process]::GetProcessById([int]$ProcessId)
                $created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
                [pscustomobject][ordered]@{Pid=[int]$process.Id;CreationTimeUtc=$created;SessionId=[string]$process.SessionId}
            }catch{return $null}finally{if($null -ne $process){$process.Dispose()}}
        }
        AssertLifecycleFence={param($RuntimeGeneration,$LeaseEpoch,$OwnerIdentity)Throw-CcodSessionError 'CCOD_LIFECYCLE_FENCE_STALE' 'No lifecycle fence adapter was supplied' $OwnerIdentity}
    }
    if ($null -ne $Adapters) {
        foreach($key in $Adapters.Keys){$defaults[$key]=$Adapters[$key]}
        if($Adapters.ContainsKey('ObserveSpecial') -and -not $Adapters.ContainsKey('ObserveSpecialIsDefault')){$defaults.ObserveSpecialIsDefault=$false}
    }
    return $defaults
}

function Close-CcodVerifiedStalePackageRoot {
    param($Probe,$StatusEvidence,[hashtable]$Adapter,[int]$TimeoutMilliseconds,$ExpectedRoot)
    $package=[pscustomobject][ordered]@{Found=$true;FullName=$Probe.PackageFullName;FamilyName=$Probe.PackageFamilyName;Version=$Probe.PackageVersion;ExecutablePath=$Probe.ExecutablePath}
    $candidate=& $Adapter.FindStalePackageRoot $package $StatusEvidence
    if($candidate.Outcome -ceq 'NoCandidate'){
        if($null -eq $ExpectedRoot){return}
        Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'The requested old-package remote server lifecycle is no longer present' $ExpectedRoot
    }
    if($candidate.Outcome -ceq 'Ambiguous'){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_AMBIGUOUS' 'Multiple old-package remote server roots were found' $candidate}
    if($candidate.Outcome -cne 'Confirmed' -or $null -eq $candidate.Snapshot){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package remote server identity could not be proven' $candidate}
    $root=$candidate.Snapshot
    if($null -ne $ExpectedRoot -and -not (& $Adapter.ProcessMatch $ExpectedRoot $root)){
        Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Worker stale-root evidence does not match the requested lifecycle' $candidate
    }
    $tree=@(& $Adapter.GetStaleTree $root $package)
    if($tree.Count -lt 1 -or @($tree|Where-Object{$_ -ne $null -and $_.Pid -eq $root.Pid -and (& $Adapter.ProcessMatch $root $_)}).Count -ne 1){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package process tree could not be proven before close' $tree}
    $byPid=@{};foreach($member in $tree){$byPid[[int]$member.Pid]=$member}
    $ordered=@($tree|Sort-Object @{Expression={-(Get-CcodTreeDepth $_ $byPid)}},@{Expression={$_.Pid}})
    $rootShutdownProven=$false
    $close=& $Adapter.RequestStaleGracefulClose $root $package
    if($close.Outcome -ceq 'IdentityChanged'){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root identity changed before graceful close' $close}
    if($close.Outcome -ceq 'SourceExited'){
        Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root disappeared before an exact graceful-close signal' $close
    }elseif($close.Outcome -ceq 'Requested'){
        if($null -eq $close.Snapshot -or -not (& $Adapter.ProcessMatch $root $close.Snapshot)){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Graceful-close request lacks exact root identity proof' $close}
        $rootShutdownProven=$true
        $wait=& $Adapter.WaitStaleProcessExit $root $package $TimeoutMilliseconds
        if($wait.Outcome -ceq 'SourceExited'){
            # The root exited, but its captured children and remote ports still require proof below.
        }elseif($wait.Outcome -ceq 'IdentityChanged'){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root identity changed while waiting for graceful close' $wait}
        elseif($wait.Outcome -ceq 'StillRunning'){
            if($null -eq $wait.Snapshot -or -not (& $Adapter.ProcessMatch $root $wait.Snapshot)){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Graceful-close wait lacks exact root identity proof' $wait}
        }else{Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root graceful-close result is invalid' $wait}
    }elseif($close.Outcome -ceq 'NotRequested'){
        if($null -eq $close.Snapshot -or -not (& $Adapter.ProcessMatch $root $close.Snapshot)){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Graceful-close refusal lacks exact root identity proof' $close}
    }else{
        Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root graceful-close result is invalid' $close
    }
    foreach($member in $ordered){
        $isRoot=$member.Pid -eq $root.Pid -and $member.CreationTimeUtc -ceq $root.CreationTimeUtc
        $current=& $Adapter.GetStaleProcess $member.Pid $package
        if($null -eq $current){
            if($isRoot -and -not $rootShutdownProven){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root disappeared before a verified shutdown action' $member}
            if(-not $isRoot -and -not $rootShutdownProven){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Captured child disappeared before root shutdown was proven' $member}
            continue
        }
        if(-not (& $Adapter.ProcessMatch $member $current)){
            if($isRoot -and -not $rootShutdownProven){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root identity changed before a verified shutdown action' $member}
            continue
        }
        $stop=& $Adapter.StopStaleProcess $member $package $TimeoutMilliseconds
        if($stop.Outcome -ceq 'Stopped'){
            if($stop.StoppedByController -isnot [bool] -or -not $stop.StoppedByController -or $null -eq $stop.Snapshot -or
               -not (& $Adapter.ProcessMatch $member $stop.Snapshot)){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package stop receipt does not prove an exact controller action' $stop}
            if($isRoot){$rootShutdownProven=$true}
        }elseif($stop.Outcome -ceq 'SourceExited'){
            if(-not $rootShutdownProven){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package tree member exited before root shutdown was proven' $stop}
        }else{Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package tree member could not be stopped with an exact identity receipt' $stop}
    }
    if(-not $rootShutdownProven){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package root shutdown action was never proven' $root}
    foreach($member in $tree){
        $current=& $Adapter.GetStaleProcess $member.Pid $package
        if($null -ne $current -and (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package tree member remains alive after close' $member}
    }
    foreach($port in @($root.RendererPort,$root.MainPort)){
        if(-not (& $Adapter.WaitPortClosed $port $TimeoutMilliseconds)){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_UNPROVEN' 'Old-package remote server port did not explicitly refuse before launch' $port}
    }
    $post=& $Adapter.FindStalePackageRoot $package $StatusEvidence
    if($post.Outcome -cne 'NoCandidate'){
        $code=if($post.Outcome -ceq 'Ambiguous'){'CCOD_STALE_PACKAGE_AMBIGUOUS'}else{'CCOD_STALE_PACKAGE_UNPROVEN'}
        Throw-CcodSessionError $code 'A same-family top-level debug root remains after stale closure' $post
    }
}

function Get-CcodExactPropertyValue {
    param($Value,[string]$Name,[ref]$Found)
    $Found.Value=$false
    if($Value -is [Collections.IDictionary]){
        foreach($key in $Value.Keys){if([string]$key -ceq $Name){$Found.Value=$true;return $Value[$key]}}
        return $null
    }
    if($null -eq $Value){return $null}
    foreach($property in $Value.PSObject.Properties){if($property.Name -ceq $Name){$Found.Value=$true;return $property.Value}}
    return $null
}

function Get-CcodAuthorizedSessionProvenance {
    param($VerifiedPackages,$Session)
    if($null -eq $Session -or $null -eq $Session.codex){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Active session provenance is unavailable' $null}
    Assert-CcodSessionExactProperties $VerifiedPackages @('schemaVersion','packages') 'CCOD_VERIFIED_PACKAGES_INVALID' 'verified packages'
    if(($VerifiedPackages.schemaVersion -isnot [int] -and $VerifiedPackages.schemaVersion -isnot [long]) -or $VerifiedPackages.schemaVersion -ne 1 -or
        ($VerifiedPackages.packages -isnot [pscustomobject] -and $VerifiedPackages.packages -isnot [Collections.IDictionary])){
        Throw-CcodSessionError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package store is invalid' $VerifiedPackages
    }
    $codex=$Session.codex
    $key='{0}|{1}|{2}' -f $codex.packageFullName,$codex.appAsarSha256,$Session.runtimeId
    $found=$false;$record=Get-CcodExactPropertyValue $VerifiedPackages.packages $key ([ref]$found)
    if(-not $found){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Exact successful session provenance is missing' $key}
    Assert-CcodSessionExactProperties $record @('packageFullName','packageVersion','appAsarSha256','runtimeId','staticClassification','dynamicOutcome','probeState','confirmedAtUtc') 'CCOD_VERIFIED_PACKAGES_INVALID' 'verified package record'
    foreach($name in @('packageFullName','packageVersion','appAsarSha256','runtimeId','staticClassification','dynamicOutcome','probeState')){
        if($record.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($record.$name)){Throw-CcodSessionError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package record fields are invalid' $record}
    }
    if(-not (Test-CcodSessionCanonicalUtc $record.confirmedAtUtc) -or $record.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$'){
        Throw-CcodSessionError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package record evidence is malformed' $record
    }
    if($record.packageFullName -cne $codex.packageFullName -or $record.packageVersion -cne $codex.packageVersion -or
        $record.appAsarSha256 -cne $codex.appAsarSha256 -or $record.runtimeId -cne $Session.runtimeId){
        Throw-CcodSessionError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package record does not match the persisted session tuple' $record
    }
    if($record.dynamicOutcome -cne 'Succeeded' -or $record.probeState -cne 'Valid' -or
        @('NativeModulePresent','UnknownOrIncompatible') -ccontains $record.staticClassification -or
        @('CandidateCompatible','VerifiedCompatible') -cnotcontains $record.staticClassification){
        Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Persisted session provenance is not authorized' $record
    }
    return $record
}

function Merge-CcodInspectionAdapters($Adapters) {
    $defaults=@{
        ReadInspectionState={param($StateRoot)
            [pscustomobject][ordered]@{
                Settings=(Read-CcodSettings -StateRoot $StateRoot)
                Status=(Read-CcodStatus -StateRoot $StateRoot)
                VerifiedPackages=(Read-CcodVerifiedPackages -StateRoot $StateRoot)
            }
        }
        GetPackageIdentity={Get-CcodPackageIdentity}
        ResolveNodeCandidate={param($NodeCandidates) Resolve-CcodNodeCandidate -NodeCandidates $NodeCandidates}
        GetPersistedSpecialIdentity={param($Status)
            if($null -ne $Status -and $null -ne $Status.session -and $Status.session.sessionState -ceq 'Active'){return $Status.session.codex}
            return $null
        }
        InvokeNode={param($NodePath,$Arguments) Invoke-CcodManagedNode -NodePath $NodePath -Arguments @($Arguments)}
        CurrentIdentity={
            $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=[string]$current.SessionId}finally{$current.Dispose()}
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            [pscustomobject][ordered]@{SessionId=$sessionId;UserSid=$sid}
        }
        ListProcesses={param($StatusEvidence)
            $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=$current.SessionId}finally{$current.Dispose()}
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            $snapshots=[Collections.Generic.List[object]]::new()
            foreach($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)){
                $snapshot=Get-CcodProcessSnapshot -ProcessId $process.Id -StatusEvidence $StatusEvidence
                if($null -ne $snapshot -and $snapshot.SessionId -eq $sessionId -and $snapshot.UserSid -ceq $sid){$snapshots.Add($snapshot)}
            }
            return $snapshots.ToArray()
        }
        ProcessMatch={param($Expected,$Actual) Test-CcodProcessMatch -Expected $Expected -Actual $Actual}
    }
    if($null -ne $Adapters){
        if($Adapters -isnot [Collections.IDictionary]){Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Inspection adapters must be a dictionary' $Adapters}
        foreach($name in @('ReadInspectionState','GetPackageIdentity','ResolveNodeCandidate','GetPersistedSpecialIdentity','InvokeNode','CurrentIdentity','ListProcesses','ProcessMatch')){
            $found=$false;$value=Get-CcodExactPropertyValue $Adapters $name ([ref]$found);if($found){$defaults[$name]=$value}
        }
    }
    return $defaults
}

function Assert-CcodInspectionState {
    param($State)
    Assert-CcodSessionExactProperties $State @('Settings','Status','VerifiedPackages') 'CCOD_STATE_BLOCKED' 'inspection state'
    if($null -eq $State.Settings -or $null -eq $State.Settings.PSObject.Properties['nodeCandidates'] -or $null -eq $State.Status -or $null -eq $State.VerifiedPackages){
        Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Inspection state is incomplete' $State
    }
}

function Get-CcodInspectionPackageIdentity {
    param([hashtable]$Adapter)
    $package=& $Adapter.GetPackageIdentity
    if($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or $package.Found -isnot [bool] -or -not $package.Found){
        Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Current package identity is unavailable' $package
    }
    foreach($name in @('FullName','FamilyName','Version','ExecutablePath')){
        if($package.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($package.$name)){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Current package identity is incomplete' $package}
    }
    return $package
}

function Get-CcodInspectionIdentity {
    param($Request,[hashtable]$Adapter)
    $identity=& $Adapter.CurrentIdentity
    if($null -eq $identity -or [string]::IsNullOrWhiteSpace([string]$identity.UserSid) -or
        [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId){
        Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Current Windows identity does not match the request' $Request.supervisorIdentity
    }
    return $identity
}

function Get-CcodInspectionRoots {
    param($Status,$Package,$Request,$Identity,[hashtable]$Adapter)
    $roots=[Collections.Generic.List[object]]::new()
    foreach($snapshot in @(& $Adapter.ListProcesses $Status)){
        if($null -eq $snapshot){continue}
        Assert-CcodSessionExactProperties $snapshot @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort') 'CCOD_SOURCE_CHANGED' 'process snapshot'
        if($snapshot.IsTopLevel -is [bool] -and $snapshot.IsTopLevel -and
            [string]$snapshot.SessionId -ceq [string]$Request.supervisorIdentity.sessionId -and $snapshot.UserSid -ceq $Identity.UserSid -and
            $snapshot.Path -is [string] -and $snapshot.Path.Equals($Package.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -and
            $snapshot.PackageFamilyName -ceq $Package.FamilyName){$roots.Add($snapshot)}
    }
    return @($roots|Sort-Object CreationTimeUtc,Pid)
}

function Test-CcodExactSpecialCommandLine {
    param($Snapshot,$Codex)
    if(@('Special','Unrelated') -cnotcontains $Snapshot.Mode -or $Snapshot.CommandLine -isnot [string]){return $false}
    $tokens=@([regex]::Matches($Snapshot.CommandLine,'(?i)(?<!\S)(?:--|-|/)(?:remote-debugging|inspect)[^\s"]*')|ForEach-Object{$_.Value})
    $expected=@('--remote-debugging-address=127.0.0.1',("--remote-debugging-port={0}" -f $Codex.rendererPort),("--inspect=127.0.0.1:{0}" -f $Codex.mainPort))
    if($tokens.Count -ne $expected.Count){return $false}
    foreach($item in $expected){if($tokens -cnotcontains $item){return $false}}
    return $true
}

function Assert-CcodInspectionSpecialSnapshot {
    param($Snapshot,$Codex,$Session,$Package,$Request,$Identity)
    if($null -eq $Snapshot -or $Snapshot.Pid -ne $Codex.pid -or $Snapshot.CreationTimeUtc -cne $Codex.creationTimeUtc -or
        -not $Snapshot.IsTopLevel -or [string]$Snapshot.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
        $Snapshot.UserSid -cne $Identity.UserSid -or -not $Snapshot.Path.Equals($Package.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or
        $Snapshot.PackageFamilyName -cne $Package.FamilyName -or $Snapshot.RendererPort -ne $Codex.rendererPort -or
        $Snapshot.MainPort -ne $Codex.mainPort -or -not (Test-CcodExactSpecialCommandLine $Snapshot $Codex) -or
        $Session.sessionId -cne $Request.supervisorIdentity.sessionId){
        Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Persisted special identity changed' $Codex
    }
}

function Assert-CcodCurrentRuntimePath {
    param($Request,$Paths)
    $runtimeRoot=Split-Path (Split-Path $Paths.CheckerPath -Parent) -Parent
    if((Split-Path $runtimeRoot -Leaf) -cne $Request.runtimeId){Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Current runtime paths do not match the authorized request runtime' $Paths}
}

function Test-CcodBridgeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Full','Renderer','Probe')][string]$Mode, [Parameter(Mandatory)]$Invocation)
    Assert-CcodSessionExactProperties $Invocation @('ExitCode','Stdout','Stderr') 'BRIDGE_PROOF_INCOMPLETE' 'bridge invocation'
    if (($Invocation.ExitCode -isnot [int] -and $Invocation.ExitCode -isnot [long]) -or $Invocation.ExitCode -ne 0 -or $Invocation.Stdout -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Invocation.Stdout) -or $Invocation.Stderr -isnot [string]) {
        Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Bridge process did not return a successful framed result' $Invocation
    }
    try { $parsed = $Invocation.Stdout | ConvertFrom-Json -ErrorAction Stop } catch { Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Bridge stdout is not one JSON object' $Invocation }
    if ($null -eq $parsed -or $parsed -is [array]) { Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Bridge stdout is not one JSON object' $Invocation }
    if($Mode -ceq 'Probe'){
        Assert-CcodSessionExactProperties $parsed @('ok','protocolVersion','main','renderer') 'CCOD_BRIDGE_JSON_INVALID' 'probe bridge proof'
        if($parsed.ok -isnot [bool] -or -not $parsed.ok -or ($parsed.protocolVersion -isnot [int] -and $parsed.protocolVersion -isnot [long]) -or $parsed.protocolVersion -ne 1){
            Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Probe bridge header is invalid' $parsed
        }
        Assert-CcodSessionExactProperties $parsed.main @('inspectorPortClosed') 'CCOD_BRIDGE_JSON_INVALID' 'probe main'
        Assert-CcodSessionExactProperties $parsed.main.inspectorPortClosed @('confirmed','code') 'CCOD_BRIDGE_JSON_INVALID' 'probe main closure'
        $closure=$parsed.main.inspectorPortClosed
        if($closure.confirmed -isnot [bool] -or $closure.code -isnot [string] -or
            ($closure.confirmed -and $closure.code -cne 'ECONNREFUSED') -or
            (-not $closure.confirmed -and @('OPEN','TIMEOUT') -cnotcontains $closure.code)){
            Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Probe main evidence is contradictory' $closure
        }
        Assert-CcodSessionExactProperties $parsed.renderer @('targetUrl','probe') 'CCOD_BRIDGE_JSON_INVALID' 'probe renderer'
        Assert-CcodSessionExactProperties $parsed.renderer.probe @('proof','targetGate') 'CCOD_BRIDGE_JSON_INVALID' 'probe renderer evidence'
        $renderer=$parsed.renderer;$proof=$renderer.probe
        if($proof.proof -isnot [bool]){Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Probe renderer Boolean is invalid' $proof}
        if($null -eq $renderer.targetUrl){
            if($proof.proof -or $null -ne $proof.targetGate){Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Absent renderer target has contradictory evidence' $renderer}
        }elseif($renderer.targetUrl -isnot [string] -or $renderer.targetUrl -cne 'app://-/index.html'){
            Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Probe renderer target URL is invalid' $renderer
        }elseif($proof.proof){
            if($proof.targetGate -isnot [string] -or $proof.targetGate -cne '782640499'){Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Positive renderer evidence is invalid' $proof}
        }elseif($null -ne $proof.targetGate -and ($proof.targetGate -isnot [string] -or $proof.targetGate -cne '782640499')){
            Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Negative renderer evidence is invalid' $proof
        }
        return $parsed
    }
    $expected = if($Mode -ceq 'Full'){@('ok','protocolVersion','main','renderer')}else{@('ok','protocolVersion','renderer')}
    Assert-CcodSessionExactProperties $parsed $expected 'BRIDGE_PROOF_INCOMPLETE' 'bridge proof'
    if ($parsed.ok -isnot [bool] -or -not $parsed.ok -or $parsed.protocolVersion -ne 1) { Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Bridge proof header is incomplete' $parsed }
    if ($Mode -ceq 'Full') {
        Assert-CcodSessionExactProperties $parsed.main @('inspectorPortClosed','payloadReport') 'BRIDGE_PROOF_INCOMPLETE' 'main proof'
        if ($null -eq $parsed.main.inspectorPortClosed -or $parsed.main.inspectorPortClosed.confirmed -isnot [bool] -or -not $parsed.main.inspectorPortClosed.confirmed -or $parsed.main.inspectorPortClosed.code -cne 'ECONNREFUSED' -or
            $null -eq $parsed.main.payloadReport -or $parsed.main.payloadReport.installed -isnot [bool] -or -not $parsed.main.payloadReport.installed) {
            Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Main proof is incomplete' $parsed
        }
    }
    Assert-CcodSessionExactProperties $parsed.renderer @('targetUrl','currentDocument','newDocumentScriptInstalled','probe') 'BRIDGE_PROOF_INCOMPLETE' 'renderer proof'
    if ($parsed.renderer.targetUrl -cne 'app://-/index.html' -or $null -eq $parsed.renderer.currentDocument -or
        $parsed.renderer.currentDocument.installed -isnot [bool] -or -not $parsed.renderer.currentDocument.installed -or
        $parsed.renderer.newDocumentScriptInstalled -isnot [bool] -or -not $parsed.renderer.newDocumentScriptInstalled -or
        $null -eq $parsed.renderer.probe -or $parsed.renderer.probe.proof -isnot [bool] -or -not $parsed.renderer.probe.proof -or
        $parsed.renderer.probe.targetGate -cne '782640499') {
        Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Renderer proof is incomplete' $parsed
    }
    return $parsed
}

function Invoke-CcodSessionCore {
    param([string]$Action, $Request, $Paths, $Adapters, [scriptblock]$Body, [switch]$InspectionAdapters, [switch]$SuppressDiagnostic)
    $transactionId = $null
    if ($null -ne $Request -and $null -ne $Request.PSObject.Properties['transactionId'] -and (Test-CcodSessionCanonicalGuid $Request.transactionId)) { $transactionId=$Request.transactionId }
    $result = New-CcodSessionResult -Action $Action -TransactionId $transactionId
    $adapter=$null;$pathsValidated=$false
    try {
        Assert-CcodSessionRequest -Request $Request -ExpectedAction $Action
        $result.transactionId=$Request.transactionId
        Assert-CcodSessionPaths -Paths $Paths
        $pathsValidated=$true
        $adapter = if($InspectionAdapters){Merge-CcodInspectionAdapters $Adapters}else{Merge-CcodSessionAdapters $Adapters}
        return & $Body $result $adapter
    } catch {
        if(Test-CcodSessionLifecycleFenceFailure $_){throw}
        $result=Set-CcodSessionFailure -Result $result -Record $_ -Stage $result.stage
        if($pathsValidated -and -not $SuppressDiagnostic){Write-CcodSessionDiagnostic $result $Action $result.transactionId $result.stage $result.error.code $Paths $adapter}
        return $result
    }
}

function Invoke-CcodInspectSession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore Inspect $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='InspectState';$state=& $adapter.ReadInspectionState $Paths.StateRoot;Assert-CcodInspectionState $state
        Assert-CcodCurrentRuntimePath $Request $Paths
        Assert-CcodSessionExactProperties $state.Status @('schemaVersion','session') 'CCOD_STATE_BLOCKED' 'inspection status'
        if(($state.Status.schemaVersion -isnot [int] -and $state.Status.schemaVersion -isnot [long]) -or $state.Status.schemaVersion -ne 1){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Inspection status schema is invalid' $state.Status}
        $package=Get-CcodInspectionPackageIdentity $adapter;$identity=Get-CcodInspectionIdentity $Request $adapter
        if($null -eq $state.Status.session){
            $roots=@(Get-CcodInspectionRoots $state.Status $package $Request $identity $adapter)
            if($roots.Count -eq 0){$result.safeState='NoCodex'}
            elseif($roots.Count -eq 1 -and $roots[0].Mode -ceq 'Ordinary' -and $null -eq $roots[0].RendererPort -and $null -eq $roots[0].MainPort){$result.source=ConvertTo-CcodSessionSource $roots[0];$result.safeState='OrdinaryRunning'}
            else{Throw-CcodSessionError 'CCOD_SOURCE_AMBIGUOUS' 'Inspection found an unowned or ambiguous current-package root set' $roots}
            $result.ok=$true;$result.outcome='Inspected';$result.stage='Inspected';return $result
        }

        $session=$state.Status.session
        Assert-CcodSessionExactProperties $session @('supervisorPid','supervisorCreationTimeUtc','sessionId','runtimeId','sessionState','codex') 'CCOD_STATE_BLOCKED' 'inspection status session'
        if($session.sessionState -cne 'Active' -or $null -eq $session.codex){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Inspection requires one persisted Active special session' $session}
        $persisted=& $adapter.GetPersistedSpecialIdentity $state.Status
        Assert-CcodSessionExactProperties $persisted @('pid','creationTimeUtc','packageFullName','packageVersion','appAsarSha256','mainPort','rendererPort','mainProbe','rendererProbe') 'CCOD_STATE_BLOCKED' 'persisted special identity'
        foreach($name in @('pid','creationTimeUtc','packageFullName','packageVersion','appAsarSha256','mainPort','rendererPort','mainProbe','rendererProbe')){
            if(-not [object]::Equals($persisted.$name,$session.codex.$name)){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Persisted special adapter evidence does not match status' $persisted}
        }
        $codex=$persisted
        if(($codex.pid -isnot [int] -and $codex.pid -isnot [long]) -or $codex.pid -lt 1 -or -not (Test-CcodSessionCanonicalUtc $codex.creationTimeUtc) -or
            $codex.packageFullName -isnot [string] -or $codex.packageVersion -isnot [string] -or $codex.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($codex.mainPort -isnot [int] -and $codex.mainPort -isnot [long]) -or ($codex.rendererPort -isnot [int] -and $codex.rendererPort -isnot [long]) -or
            $codex.mainPort -lt 1 -or $codex.mainPort -gt 65535 -or $codex.rendererPort -lt 1 -or $codex.rendererPort -gt 65535 -or
            $codex.mainPort -eq $codex.rendererPort -or $codex.mainProbe -cne 'Closed' -or $codex.rendererProbe -cne 'BridgeValid'){
            Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Persisted special status evidence is invalid' $codex
        }
        Get-CcodAuthorizedSessionProvenance $state.VerifiedPackages $session|Out-Null
        if($package.FullName -cne $codex.packageFullName -or $package.Version -cne $codex.packageVersion){Throw-CcodSessionError 'CCOD_STATE_STALE_PACKAGE' 'Current package build differs from persisted status' $package}
        $preRoots=@(Get-CcodInspectionRoots $state.Status $package $Request $identity $adapter)
        if($preRoots.Count -ne 1){Throw-CcodSessionError 'CCOD_SOURCE_AMBIGUOUS' 'Inspection requires exactly one eligible pre-probe root' $preRoots}
        $special=$preRoots[0];Assert-CcodInspectionSpecialSnapshot $special $codex $session $package $Request $identity
        $node=& $adapter.ResolveNodeCandidate @($state.Settings.nodeCandidates)
        if($null -eq $node -or $node.Found -isnot [bool] -or -not $node.Found -or $node.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($node.Path) -or
            $null -eq $node.Capabilities -or $node.Capabilities.Supported -isnot [bool] -or -not $node.Capabilities.Supported){
            Throw-CcodSessionError 'CCOD_NODE_CANDIDATE_INVALID' 'No installer-approved Node candidate is available' $node
        }
        $nodeAuthorized=$false
        foreach($candidate in @($state.Settings.nodeCandidates)){
            if($candidate -is [string] -and -not [string]::IsNullOrWhiteSpace($candidate)){
                try{if([IO.Path]::GetFullPath($candidate).Equals([IO.Path]::GetFullPath($node.Path),[StringComparison]::OrdinalIgnoreCase)){$nodeAuthorized=$true}}catch{}
            }
        }
        if(-not $nodeAuthorized){Throw-CcodSessionError 'CCOD_NODE_CANDIDATE_INVALID' 'Resolved Node is outside configured candidates' $node}
        $result.stage='InspectProbe';$bridge=Invoke-CcodSessionBridge -Request $Request -Mode Probe -NodePath $node.Path -Paths $Paths -RendererPort $codex.rendererPort -MainPort $codex.mainPort -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter
        $postRoots=@(Get-CcodInspectionRoots $state.Status $package $Request $identity $adapter)
        if($postRoots.Count -eq 0){$result.ok=$true;$result.outcome='Inspected';$result.safeState='NoCodex';$result.stage='Inspected';return $result}
        if($postRoots.Count -eq 1 -and $postRoots[0].Mode -ceq 'Ordinary' -and $null -eq $postRoots[0].RendererPort -and $null -eq $postRoots[0].MainPort){
            $result.source=ConvertTo-CcodSessionSource $postRoots[0];$result.ok=$true;$result.outcome='Inspected';$result.safeState='OrdinaryRunning';$result.stage='Inspected';return $result
        }
        if($postRoots.Count -ne 1 -or -not (& $adapter.ProcessMatch $special $postRoots[0])){Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Eligible root set changed during inspection' $postRoots}
        Assert-CcodInspectionSpecialSnapshot $postRoots[0] $codex $session $package $Request $identity
        if(-not $bridge.main.inspectorPortClosed.confirmed){Throw-CcodSessionError 'CCOD_MAIN_INSPECTOR_OPEN' 'Main Inspector is not explicitly closed' $bridge.main.inspectorPortClosed}
        $result.special=ConvertTo-CcodSessionSpecial $postRoots[0]
        $result.safeState=if($bridge.renderer.probe.proof){'SpecialValidated'}else{'RendererRepairRequired'}
        $result.ok=$true;$result.outcome='Inspected';$result.stage='Inspected';return $result
    } -InspectionAdapters -SuppressDiagnostic
}

function Invoke-CcodActivationSession {
    param([ValidateSet('Apply','RepairStale')][string]$Action,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    $repairStale=$Action -ceq 'RepairStale'
    return Invoke-CcodSessionCore $Action $Request $Paths $Adapters {
        param($result,$adapter)
        $repairIdentity=$null
        if($repairStale){$repairIdentity=Assert-CcodLiveSupervisorIdentity $Request $adapter}
        $result.stage='StaticProbe';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks activation' $state.Damage}
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath
        $result.package=ConvertTo-CcodSessionPackage $probe
        $suppressionKey=Get-CcodSuppressionKey -PackageFullName $probe.PackageFullName -AppAsarSha256 $probe.AppAsarSha256 -RuntimeId $Request.runtimeId
        $state=& $adapter.ReadState $Paths.StateRoot $suppressionKey
        if($state.StatusRebuildRequired){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Status requires a dedicated live rebuild before activation' $state.Damage}
        if($probe.StaticClassification -cne 'CandidateCompatible' -or -not $probe.Ready){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Package is not authorized for activation' $probe}
        $source=$Request.source
        if($repairStale){
            $result.source=ConvertTo-CcodSessionStaleSource $source
            if([string]$source.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $source.UserSid -cne $repairIdentity.UserSid -or
               $source.PackageFamilyName -cne $probe.PackageFamilyName -or
               $source.Path.Equals($probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)){
                Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Requested stale source is outside the live supervisor package boundary' $source
            }
            $currentRoots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
            if($currentRoots.Count -ne 0){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_AMBIGUOUS' 'A current-package root conflicts with stale repair' $currentRoots}
            $result.stage='StaleClose'
            Close-CcodVerifiedStalePackageRoot -Probe $probe -StatusEvidence $state.Status -Adapter $adapter -TimeoutMilliseconds (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds) -ExpectedRoot $source
            $currentRoots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
            if($currentRoots.Count -ne 0){Throw-CcodSessionError 'CCOD_STALE_PACKAGE_AMBIGUOUS' 'A current-package root appeared during stale repair' $currentRoots}
            $source=$null
        }else{
            if($null -eq $source -and -not $Request.existingOnly){
                $roots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
                if($roots.Count -gt 1 -or ($roots.Count -eq 1 -and $roots[0].Mode -cne 'Ordinary')){Throw-CcodSessionError 'CCOD_SOURCE_AMBIGUOUS' 'Current package roots do not prove one ordinary source' $roots}
                if($roots.Count -eq 1){$source=$roots[0]}
            }
            if($null -ne $source){
                $identity=& $adapter.CurrentIdentity
                if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
                    [string]$source.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $source.UserSid -cne $identity.UserSid -or
                    -not $source.Path.Equals($probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $source.PackageFamilyName -cne $probe.PackageFamilyName){
                    Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Source identity is outside the current supervisor package boundary' $source
                }
                $actual=& $adapter.GetProcess $source.Pid $state.Status
                if($null -eq $actual -or -not (& $adapter.ProcessMatch $source $actual)){Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Source identity changed before transaction start' $source}
                $source=$actual;$result.source=ConvertTo-CcodSessionSource $source
            }
        }
        $journalPackage=ConvertTo-CcodJournalPackage $probe
        $result.stage='IntentWritten';$transition=Invoke-CcodSessionMutation $Request $adapter 'NewTransition' @($Paths.TransitionPath,$source,$journalPackage,$Request.runtimeId,$null,$null,$Request.transactionId)
        if($null -ne $source){
            $result.stage='StopRequested';$transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'IntentWritten','StopRequested',$null,$null,$null,$null)
            $stop=Invoke-CcodSessionMutation $Request $adapter 'StopProcess' @($source,$state.Status,(Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))
            if($stop.Outcome -cne 'Stopped' -or $stop.StoppedByController -isnot [bool] -or -not $stop.StoppedByController){
                Invoke-CcodSessionMutation $Request $adapter 'CompleteTransition' @($Paths.TransitionPath,$Paths.TransitionLogPath,$Request.transactionId,'Cancelled')|Out-Null
                if($stop.Outcome -ceq 'SourceExited'){$result.ok=$true;$result.outcome='NoAction';$result.safeState='NoCodex';$result.stage='Cancelled';return $result}
                Throw-CcodSessionError 'CCOD_STOP_UNCONFIRMED' 'Only an exact Stopped receipt authorizes special launch' $stop
            }
            $result.stage='OrdinaryStopped';$transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'StopRequested','OrdinaryStopped',$null,$null,$null,$null)
        } else {
            $result.stage='OrdinaryStopped';$transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'IntentWritten','OrdinaryStopped',$null,$null,$null,$null)
        }
        $currentStage='OrdinaryStopped';$special=$null;$renderer=$Request.rendererPort;$main=$Request.mainPort;$recoveryAttempted=$false
        try {
            $rendererExcluded=if($null -eq $main){@()}else{@($main)}
            if($null -eq $renderer){$renderer=& $adapter.GetPreferredRendererPort @rendererExcluded}
            if($null -eq $renderer){$renderer=& $adapter.GetPort @rendererExcluded}
            if($null -eq $main){$main=& $adapter.GetPort @($renderer)}
            if($null -eq $renderer -or $null -eq $main -or $renderer -eq $main){Throw-CcodSessionError 'CCOD_PORT_UNAVAILABLE' 'Two distinct loopback ports are required' $null}
            $result.stage='SpecialLaunchRequested';$transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'OrdinaryStopped','SpecialLaunchRequested',$null,$null,$renderer,$main);$currentStage='SpecialLaunchRequested'
            $start=Invoke-CcodSessionMutation $Request $adapter 'StartSpecial' @($renderer,$main,(Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))
            if($start.Outcome -cne 'Started' -or $null -eq $start.Snapshot){Throw-CcodSessionError 'CCOD_SPECIAL_START_FAILED' 'Special startup was not proven' $start}
            $special=$start.Snapshot;$result.special=ConvertTo-CcodSessionSpecial $special
            $result.stage='SpecialStarted';$transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'SpecialLaunchRequested','SpecialStarted',$special,$null,$null,$null);$currentStage='SpecialStarted'
            $bridge=Invoke-CcodSessionBridge -Request $Request -Mode Full -NodePath $probe.NodePath -Paths $Paths -RendererPort $renderer -MainPort $main -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter
            $result.probes=ConvertTo-CcodPublicBridgeProbes $bridge Full
            $result.stage='Validated';$transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'SpecialStarted','Validated',$null,$null,$null,$null);$currentStage='Validated'
            $status=[pscustomobject][ordered]@{schemaVersion=1;session=[pscustomobject][ordered]@{supervisorPid=[int]$Request.supervisorIdentity.pid;supervisorCreationTimeUtc=$Request.supervisorIdentity.creationTimeUtc;sessionId=$Request.supervisorIdentity.sessionId;runtimeId=$Request.runtimeId;sessionState='Active';codex=[pscustomobject][ordered]@{pid=[int]$special.Pid;creationTimeUtc=$special.CreationTimeUtc;packageFullName=$probe.PackageFullName;packageVersion=$probe.PackageVersion;appAsarSha256=$probe.AppAsarSha256;mainPort=[int]$main;rendererPort=[int]$renderer;mainProbe='Closed';rendererProbe='BridgeValid'}}}
            $live=[pscustomobject][ordered]@{Valid=$true;runtimeId=$Request.runtimeId;pid=[int]$special.Pid;creationTimeUtc=$special.CreationTimeUtc;packageFullName=$probe.PackageFullName;packageVersion=$probe.PackageVersion;appAsarSha256=$probe.AppAsarSha256;mainPort=[int]$main;rendererPort=[int]$renderer;mainProbe='Closed';rendererProbe='BridgeValid'}
            Invoke-CcodSessionMutation $Request $adapter 'WriteStatus' @($Paths.StateRoot,$status,$live)|Out-Null
            $verified=& $adapter.ReadVerified $Paths.StateRoot;$succeeded=New-CcodVerifiedStoreWithRecord $verified $probe $Request.runtimeId 'Succeeded' 'Valid' (& $adapter.UtcNow);Invoke-CcodSessionMutation $Request $adapter 'WriteVerified' @($Paths.StateRoot,$succeeded)|Out-Null
            Invoke-CcodSessionMutation $Request $adapter 'CompleteTransition' @($Paths.TransitionPath,$Paths.TransitionLogPath,$Request.transactionId,'Activated')|Out-Null
            $result.ok=$true;$result.outcome='Activated';$result.safeState='SpecialValidated';$result.stage='Completed';return $result
        } catch {
            if(Test-CcodSessionLifecycleFenceFailure $_){throw}
            Write-CcodSessionDiagnostic $result $Action $Request.transactionId $result.stage (Get-CcodSessionErrorCode $_) $Paths $adapter
            if($recoveryAttempted){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recursive recovery is forbidden' $_}
            $recoveryAttempted=$true
            $recoveryRenderer=$null;$recoveryMain=$null
            if(@('SpecialLaunchRequested','SpecialStarted','Validated') -ccontains $currentStage){$recoveryRenderer=$renderer;$recoveryMain=$main}
            return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $currentStage $special $recoveryRenderer $recoveryMain $Request.transactionId
        }
    }
}

function Invoke-CcodApplySession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodActivationSession -Action Apply -Request $Request -Paths $Paths -Adapters $Adapters
}

function Invoke-CcodRepairStaleSession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodActivationSession -Action RepairStale -Request $Request -Paths $Paths -Adapters $Adapters
}

function Invoke-CcodRepairRenderer {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore RepairRenderer $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='RepairState';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed -or $null -eq $state.Status.session -or $null -eq $state.Status.session.codex){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'No persisted special session is repairable' $state.Damage}
        $session=$state.Status.session;$codex=$session.codex
        if($session.sessionState -cne 'Active'){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Only an Active persisted session is repairable' $session}
        Get-CcodAuthorizedSessionProvenance $state.VerifiedPackages $session|Out-Null
        Assert-CcodCurrentRuntimePath $Request $Paths
        $package=& $adapter.GetPackageIdentity
        if($null -eq $package -or $package.Found -isnot [bool] -or -not $package.Found -or
            $package.FullName -isnot [string] -or $package.Version -isnot [string] -or $package.FamilyName -isnot [string] -or $package.ExecutablePath -isnot [string] -or
            $package.FullName -cne $codex.packageFullName -or $package.Version -cne $codex.packageVersion){
            Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Fresh package identity does not match the persisted session' $package
        }
        $identity=& $adapter.CurrentIdentity
        if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]::IsNullOrWhiteSpace([string]$identity.UserSid)){
            Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Current Windows identity does not match renderer repair authority' $Request.supervisorIdentity
        }
        $roots=@(Get-CcodInspectionRoots $state.Status $package $Request $identity $adapter)
        if($roots.Count -ne 1){Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Renderer repair requires one exact current-package root' $roots}
        $current=$roots[0]
        if($null -eq $current -or $current.Pid -ne $codex.pid -or $current.CreationTimeUtc -cne $codex.creationTimeUtc -or -not $current.IsTopLevel -or
            [string]$current.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
            $current.UserSid -cne $identity.UserSid -or -not $current.Path.Equals($package.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or
            $current.PackageFamilyName -cne $package.FamilyName -or $current.RendererPort -ne $codex.rendererPort -or $current.MainPort -ne $codex.mainPort -or
            -not (Test-CcodExactSpecialCommandLine $current $codex) -or $session.sessionId -cne $Request.supervisorIdentity.sessionId){
            Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Persisted special identity changed before renderer repair' $codex
        }
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        if($null -eq $probe -or -not $probe.Ready -or @('CandidateCompatible','VerifiedCompatible') -cnotcontains $probe.StaticClassification -or
            $probe.PackageFullName -cne $codex.packageFullName -or $probe.PackageVersion -cne $codex.packageVersion -or $probe.AppAsarSha256 -cne $codex.appAsarSha256 -or
            $probe.PackageFamilyName -cne $package.FamilyName -or -not $probe.ExecutablePath.Equals($package.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)){
            Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Live package does not match persisted renderer repair evidence' $probe
        }
        $recoveryAttempted=$false
        try{
            if(-not (& $adapter.WaitPortClosed $codex.mainPort (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))){Throw-CcodSessionError 'CCOD_MAIN_INSPECTOR_OPEN' 'Main Inspector refusal is not proven before renderer repair' $codex.mainPort}
            $bridge=Invoke-CcodSessionBridge -Request $Request -Mode Renderer -NodePath $probe.NodePath -Paths $Paths -RendererPort $codex.rendererPort -MainPort $null -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter
            $result.probes=ConvertTo-CcodPublicBridgeProbes $bridge Renderer;$result.special=ConvertTo-CcodSessionSpecial $current
            $migratedStatus=[pscustomobject][ordered]@{schemaVersion=1;session=[pscustomobject][ordered]@{
                supervisorPid=[int]$Request.supervisorIdentity.pid
                supervisorCreationTimeUtc=[string]$Request.supervisorIdentity.creationTimeUtc
                sessionId=[string]$Request.supervisorIdentity.sessionId
                runtimeId=[string]$Request.runtimeId
                sessionState='Active'
                codex=$codex
            }}
            $live=[pscustomobject][ordered]@{Valid=$true;runtimeId=$Request.runtimeId;pid=[int]$codex.pid;creationTimeUtc=$codex.creationTimeUtc;packageFullName=$codex.packageFullName;packageVersion=$codex.packageVersion;appAsarSha256=$codex.appAsarSha256;mainPort=[int]$codex.mainPort;rendererPort=[int]$codex.rendererPort;mainProbe='Closed';rendererProbe='BridgeValid'}
            Invoke-CcodSessionMutation $Request $adapter 'WriteStatus' @($Paths.StateRoot,$migratedStatus,$live)|Out-Null
            $verified=& $adapter.ReadVerified $Paths.StateRoot
            $succeeded=New-CcodVerifiedStoreWithRecord $verified $probe $Request.runtimeId 'Succeeded' 'Valid' (& $adapter.UtcNow)
            Invoke-CcodSessionMutation $Request $adapter 'WriteVerified' @($Paths.StateRoot,$succeeded)|Out-Null
            $result.ok=$true;$result.outcome='NoAction';$result.safeState='SpecialValidated';$result.stage='RendererRepaired';return $result
        }catch{
            if(Test-CcodSessionLifecycleFenceFailure $_){throw}
            Write-CcodSessionDiagnostic $result 'RepairRenderer' $Request.transactionId $result.stage (Get-CcodSessionErrorCode $_) $Paths $adapter
            if($recoveryAttempted){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recursive renderer recovery is forbidden' $_}
            $recoveryAttempted=$true
            $journalPackage=ConvertTo-CcodJournalPackage $probe
            $transition=Invoke-CcodSessionMutation $Request $adapter 'NewTransition' @($Paths.TransitionPath,$null,$journalPackage,$Request.runtimeId,$null,$null,$Request.transactionId)
            $transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'IntentWritten','OrdinaryStopped',$null,$null,$null,$null)
            $transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'OrdinaryStopped','SpecialLaunchRequested',$null,$null,$codex.rendererPort,$codex.mainPort)
            $transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'SpecialLaunchRequested','SpecialStarted',$current,$null,$null,$null)
            return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe 'SpecialStarted' $current $codex.rendererPort $codex.mainPort $Request.transactionId
        }
    } -SuppressDiagnostic
}

function Invoke-CcodCloseSession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore Close $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='CloseState';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks close' $state.Damage}
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        $roots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
        $statusCodex=$null;if($null -ne $state.Status.session){$statusCodex=$state.Status.session.codex}
        $target=$null;$isSpecial=$false
        if($null -ne $statusCodex){
            $candidate=& $adapter.GetProcess $statusCodex.pid $state.Status
            $recordedExact=$roots.Count -eq 1 -and $null -ne $candidate -and $candidate.CreationTimeUtc -ceq $statusCodex.creationTimeUtc -and (& $adapter.ProcessMatch $roots[0] $candidate)
            if($recordedExact){
                $target=$candidate;$isSpecial=$true
            }else{
                $identity=Get-CcodStrictProcessIdentityObservation -ProcessId ([int]$statusCodex.pid) -ExpectedCreationTimeUtc ([string]$statusCodex.creationTimeUtc) -Adapter $adapter
                if($identity.Outcome -in @('Absent','IdentityChanged') -and $roots.Count -eq 1){
                    $target=$roots[0]
                    $statusCodex=$null
                    $isSpecial=$target.Mode -cne 'Ordinary'
                    if($isSpecial -and ($target.RendererPort -isnot [int] -or $target.MainPort -isnot [int] -or
                       $target.RendererPort -lt 1 -or $target.RendererPort -gt 65535 -or $target.MainPort -lt 1 -or $target.MainPort -gt 65535 -or
                       $target.RendererPort -eq $target.MainPort)){
                        Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'A replacement debug root lacks one valid distinct port pair' $target
                    }
                }else{
                    Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active root cannot be safely replaced' $statusCodex
                }
            }
        }else{
            if($roots.Count -gt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Multiple current-package close roots are ambiguous' $roots}
            if($roots.Count -eq 1){
                $target=$roots[0]
                if($target.Mode -cne 'Ordinary'){
                    if($null -eq $target.RendererPort -or $null -eq $target.MainPort -or $target.RendererPort -eq $target.MainPort){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'A status-less debug root lacks one valid distinct port pair' $target}
                    $isSpecial=$true
                }
            }
        }
        if($null -ne $Request.source){
            if($null -eq $target -or -not (& $adapter.ProcessMatch $Request.source $target)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Requested close source is not the one verified current root' $Request.source}
        }
        if($null -eq $target){$result.ok=$true;$result.outcome='Closed';$result.safeState='Closed';$result.stage='Closed';return $result}
        $tree=@(& $adapter.GetTree $target $state.Status)
        if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Current close target tree is not exact and verified' $target}
        $renderer=$null;$main=$null;$source=$target
        if($isSpecial){if($null -ne $statusCodex){$renderer=$statusCodex.rendererPort;$main=$statusCodex.mainPort}else{$renderer=$target.RendererPort;$main=$target.MainPort};$source=$null;$result.special=ConvertTo-CcodSessionSpecial $target}else{$result.source=ConvertTo-CcodSessionSource $target}
        $journalPackage=ConvertTo-CcodJournalPackage $probe
        $result.stage='IntentWritten';$transition=Invoke-CcodSessionMutation $Request $adapter 'NewTransition' @($Paths.TransitionPath,$source,$journalPackage,$Request.runtimeId,$renderer,$main,$Request.transactionId)
        $result.stage='CloseRequested';$specialIdentity=if($isSpecial){$target}else{$null}
        $transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'IntentWritten','CloseRequested',$specialIdentity,$null,$null,$null)
        Invoke-CcodCloseVerifiedTree $Request $tree $state.Status $adapter $Request.timeoutMilliseconds $renderer $main
        $transition=Invoke-CcodSessionMutation $Request $adapter 'SetTransition' @($Paths.TransitionPath,$Request.transactionId,'CloseRequested','Closed',$null,$null,$null,$null)
        return Complete-CcodCloseResult $result $Request $Paths $adapter $Request.transactionId
    }
}

function Invoke-CcodRecoverSession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore Recover $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='RecoverState';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks recovery' $state.Damage}
        if($null -ne $state.Transition.activeTransaction){
            $activeTransaction = $state.Transition.activeTransaction
            if($activeTransaction.stage -ceq 'Recovered' -and $activeTransaction.runtimeId -cne $Request.runtimeId){
                $cleared = & $adapter.ClearCommittedTransition $Paths.TransitionPath $Paths.TransitionLogPath $activeTransaction.transactionId 'Recovered'
                if($null -eq $cleared -or $cleared.Outcome -ne 'Completed'){
                    Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'A prior recovery from another runtime is not durably complete' $activeTransaction
                }
                $state=& $adapter.ReadState $Paths.StateRoot $null
                if($null -ne $state.Transition.activeTransaction){
                    Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'A committed prior recovery did not clear the active transition' $state.Transition.activeTransaction
                }
            } else {
                $replayed=Invoke-CcodReplayTransition -Request $Request -Paths $Paths -Transition $activeTransaction -Adapters $adapter
                if($Request.restartOrdinary -or -not $replayed.ok){return $replayed}
                $state=& $adapter.ReadState $Paths.StateRoot $null
                if($null -ne $state.Transition.activeTransaction){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Older transaction did not clear before separate close intent' $state.Transition.activeTransaction}
            }
        }
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        $roots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
        $statusCodex=$null;if($null -ne $state.Status.session){$statusCodex=$state.Status.session.codex}
        if($Request.restartOrdinary){
            $special=$null;$renderer=$null;$main=$null
            if($null -ne $statusCodex){
                $candidate=& $adapter.GetProcess $statusCodex.pid $state.Status
                if($roots.Count -ne 1 -or $null -eq $candidate -or $candidate.CreationTimeUtc -cne $statusCodex.creationTimeUtc -or
                    -not (& $adapter.ProcessMatch $roots[0] $candidate) -or $candidate.RendererPort -ne $statusCodex.rendererPort -or $candidate.MainPort -ne $statusCodex.mainPort){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Persisted special identity is missing, changed, or accompanied by another root' $statusCodex}
                $special=$candidate;$renderer=$statusCodex.rendererPort;$main=$statusCodex.mainPort
            } else {
                if($roots.Count -gt 1){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Multiple current-package roots make normalization ambiguous' $roots}
                if($roots.Count -eq 1 -and $roots[0].Mode -cne 'Ordinary'){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'A status-less debug root is not owned for ordinary recovery' $roots[0]}
            }
            if($null -eq $special -and $roots.Count -eq 1){
                & $adapter.WriteStatus $Paths.StateRoot ([pscustomobject][ordered]@{schemaVersion=1;session=$null}) $null
                $result.source=ConvertTo-CcodSessionSource $roots[0];$result.ok=$true;$result.outcome='NoAction';$result.safeState='OrdinaryRunning';$result.stage='OrdinaryKept';return $result
            }
            $journalPackage=ConvertTo-CcodJournalPackage $probe
            $transition=& $adapter.NewTransition $Paths.TransitionPath $null $journalPackage $Request.runtimeId $null $null $Request.transactionId
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'OrdinaryStopped' $null $null $null $null
            $currentStage='OrdinaryStopped'
            if($null -ne $special){
                $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'OrdinaryStopped' 'SpecialLaunchRequested' $null $null $renderer $main
                $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'SpecialLaunchRequested' 'SpecialStarted' $special $null $null $null
                $currentStage='SpecialStarted';$result.special=ConvertTo-CcodSessionSpecial $special
            }
            return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $currentStage $special $renderer $main $Request.transactionId
        }
        $target=$null;$isSpecial=$false
        if($null -ne $statusCodex){
            $candidate=& $adapter.GetProcess $statusCodex.pid $state.Status
            if($roots.Count -ne 1 -or $null -eq $candidate -or $candidate.CreationTimeUtc -cne $statusCodex.creationTimeUtc -or -not (& $adapter.ProcessMatch $roots[0] $candidate)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active root is missing, changed, or accompanied by another root' $statusCodex}
            $target=$candidate;$isSpecial=$true
        } else {
            if($roots.Count -gt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Multiple current-package close roots are ambiguous' $roots}
            if($roots.Count -eq 1){
                $target=$roots[0]
                if($target.Mode -cne 'Ordinary'){
                    if($null -eq $target.RendererPort -or $null -eq $target.MainPort -or $target.RendererPort -eq $target.MainPort){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'A status-less debug root lacks one valid distinct port pair' $target}
                    $isSpecial=$true
                }
            }
        }
        if($null -eq $target){$result.ok=$true;$result.outcome='Closed';$result.safeState='Closed';$result.stage='Closed';return $result}
        $tree=@(& $adapter.GetTree $target $state.Status)
        if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Current close target tree is not exact and verified' $target}
        $renderer=$null;$main=$null;$source=$target
        if($isSpecial){if($null -ne $statusCodex){$renderer=$statusCodex.rendererPort;$main=$statusCodex.mainPort}else{$renderer=$target.RendererPort;$main=$target.MainPort};$source=$null;$result.special=ConvertTo-CcodSessionSpecial $target}else{$result.source=ConvertTo-CcodSessionSource $target}
        $journalPackage=ConvertTo-CcodJournalPackage $probe
        $result.stage='IntentWritten';$transition=& $adapter.NewTransition $Paths.TransitionPath $source $journalPackage $Request.runtimeId $renderer $main $Request.transactionId
        $result.stage='CloseRequested';$specialIdentity=if($isSpecial){$target}else{$null}
        $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'CloseRequested' $specialIdentity $null $null $null
        Invoke-CcodCloseVerifiedTree $Request $tree $state.Status $adapter $Request.timeoutMilliseconds $renderer $main
        $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'CloseRequested' 'Closed' $null $null $null $null
        return Complete-CcodCloseResult $result $Request $Paths $adapter $Request.transactionId
    }
}

function Invoke-CcodReplayTransition {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,[Parameter(Mandatory)]$Transition,$Adapters)
    return Invoke-CcodSessionCore Recover $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage=$Transition.stage
        $state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks transition replay' $state.Damage}
        if($Transition.stage -ceq 'Closed'){
            $portObservation=if($null -eq $Transition.mainPort){'NotApplicable'}else{'Indeterminate'}
            $observed=[pscustomobject][ordered]@{StopObservation='CloseTreeAbsent';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$portObservation;SpecialCandidates=@();OrdinaryCandidates=@()}
            $decision=Get-CcodReplayDecision -Transition $Transition -Observed $observed
            if($decision.Action -cne 'CompleteClosed'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Closed replay did not select archival completion' $decision}
            return Complete-CcodCloseResult $result $Request $Paths $adapter $Transition.transactionId
        }
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        $crossRuntimeCloseReplay=$Transition.stage -ceq 'CloseRequested' -and $Request.restartOrdinary -and
            $null -eq $Transition.specialPid -and $null -eq $Transition.rendererPort -and $null -eq $Transition.mainPort
        if((($Transition.runtimeId -cne $Request.runtimeId) -and -not $crossRuntimeCloseReplay) -or
            $Transition.packageFullName -cne $probe.PackageFullName -or $Transition.appAsarSha256 -cne $probe.AppAsarSha256){
            Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'The active runtime package does not match the durable transition identity' $Transition
        }
        if($Transition.stage -ceq 'CloseRequested'){
            $identity=& $adapter.CurrentIdentity
            if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]::IsNullOrWhiteSpace([string]$identity.UserSid)){
                Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Close replay supervisor does not match the current Windows session identity' $Request.supervisorIdentity
            }
            $portObservation=if($null -eq $Transition.mainPort){'NotApplicable'}else{'Indeterminate'}
            $recordedPid=if($null -ne $Transition.specialPid){$Transition.specialPid}else{$Transition.sourcePid}
            $recordedTime=if($null -ne $Transition.specialPid){$Transition.specialCreationTimeUtc}else{$Transition.sourceCreationTimeUtc}
            $roots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
            # A recovery can be interrupted after the old root exits but after the
            # replacement ordinary Codex has already been launched.  In that
            # narrow case the durable CloseRequested record still names the old
            # PID, while exactly one new ordinary root is present.  Adopt it only
            # for a restart-enabled Recover request and only when its start time
            # is strictly after the transaction update; this keeps ambiguous or
            # pre-existing roots fail-closed.
            if($Request.restartOrdinary -and $null -eq $Transition.specialPid -and $roots.Count -eq 1){
                $candidateRoot=$roots[0]
                $recordedCurrent=$null
                if($null -ne $recordedPid){$recordedCurrent=& $adapter.GetProcess $recordedPid $state.Status}
                $transitionTime=[DateTime]::MinValue;$candidateTime=[DateTime]::MinValue
                $timeEvidence=$Transition.updatedAtUtc -is [string] -and $candidateRoot.CreationTimeUtc -is [string] -and
                    [DateTime]::TryParseExact($Transition.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$transitionTime) -and
                    [DateTime]::TryParseExact($candidateRoot.CreationTimeUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$candidateTime)
                if($null -eq $recordedCurrent -and $candidateRoot.Mode -ceq 'Ordinary' -and $candidateRoot.IsTopLevel -is [bool] -and $candidateRoot.IsTopLevel -and
                    $null -eq $candidateRoot.RendererPort -and $null -eq $candidateRoot.MainPort -and $timeEvidence -and $candidateTime -gt $transitionTime){
                    & $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'CloseRequested' 'Recovered' $null $candidateRoot $null $null | Out-Null
                    return Complete-CcodRecoveredReplay $result $Request $Paths $adapter $probe $candidateRoot $Transition.transactionId
                }
            }
            if($roots.Count -eq 0){
                $cold=[pscustomobject][ordered]@{StopObservation='CloseTreeIndeterminate';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$portObservation;SpecialCandidates=@();OrdinaryCandidates=@()}
                $decision=Get-CcodReplayDecision -Transition $Transition -Observed $cold
                Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Cold close replay cannot prove absence of the complete recorded tree' $decision
            }
            if($roots.Count -ne 1 -or $roots[0].Pid -ne $recordedPid -or $roots[0].CreationTimeUtc -cne $recordedTime){
                Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close replay requires exactly the one journaled current-package root' $roots
            }
            $current=& $adapter.GetProcess $recordedPid $state.Status
            if($null -eq $current -or $current.CreationTimeUtc -cne $recordedTime -or -not $current.IsTopLevel -or
                [string]$current.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $current.UserSid -cne $identity.UserSid -or
                -not $current.Path.Equals($probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $current.PackageFamilyName -cne $probe.PackageFamilyName -or
                -not (& $adapter.ProcessMatch $roots[0] $current)){
                $cold=[pscustomobject][ordered]@{StopObservation='CloseTreeIndeterminate';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$portObservation;SpecialCandidates=@();OrdinaryCandidates=@()}
                $decision=Get-CcodReplayDecision -Transition $Transition -Observed $cold
                Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Cold close replay cannot prove absence of the complete recorded tree' $decision
            }
            $tree=@(& $adapter.GetTree $current $state.Status)
            if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded close root does not yield a verified tree' $current}
            if($null -ne $Transition.specialPid){
                $fact=[pscustomobject][ordered]@{Process=$current;Evidence='PersistedIdentity';Validation='Indeterminate'}
                $present=[pscustomobject][ordered]@{StopObservation='CloseTreePresent';RecoveryObservation='NotApplicable';SpecialObservation='Confirmed';PortObservation=$portObservation;SpecialCandidates=@($fact);OrdinaryCandidates=@()}
            } else {
                $present=[pscustomobject][ordered]@{StopObservation='CloseTreePresent';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation='NotApplicable';SpecialCandidates=@();OrdinaryCandidates=@($current)}
            }
            $decision=Get-CcodReplayDecision -Transition $Transition -Observed $present
            if($decision.Action -cne 'CloseRecordedTree'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close replay did not authorize the exact recorded tree' $decision}
            Invoke-CcodCloseVerifiedTree $Request $tree $state.Status $adapter $Request.timeoutMilliseconds $Transition.rendererPort $Transition.mainPort
            $closedPort=if($null -eq $Transition.mainPort){'NotApplicable'}else{'BothRefused'}
            $absent=[pscustomobject][ordered]@{StopObservation='CloseTreeAbsent';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$closedPort;SpecialCandidates=@();OrdinaryCandidates=@()}
            $decision=Get-CcodReplayDecision -Transition $Transition -Observed $absent
            if($decision.Action -cne 'CompleteClosed'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree absence did not authorize completion' $decision}
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'CloseRequested' 'Closed' $null $null $null $null
            return Complete-CcodCloseResult $result $Request $Paths $adapter $Transition.transactionId
        }
        $ordinary=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter|Where-Object{$_.Mode -ceq 'Ordinary'})
        $stopObservation='NotApplicable';$recoveryObservation='NotApplicable'
        if($Transition.stage -ceq 'StopRequested'){
            $expected=& $adapter.GetProcess $Transition.sourcePid $state.Status
            if($null -eq $expected){$stopObservation='ExitedDuringPrimary5s'}
            elseif($expected.CreationTimeUtc -cne $Transition.sourceCreationTimeUtc){$stopObservation='IdentityChangedDuringPrimary5s'}
            else{
                $stopObservation='SameAliveAfterPrimary5s'
                for($index=0;$index -lt 5;$index++){
                    & $adapter.Delay 1000;$current=& $adapter.GetProcess $Transition.sourcePid $state.Status
                    if($null -eq $current){$stopObservation='ExitedDuringPrimary5s';break}
                    if(-not (& $adapter.ProcessMatch $expected $current)){$stopObservation='IdentityChangedDuringPrimary5s';break}
                }
                if($stopObservation -ceq 'SameAliveAfterPrimary5s'){
                    $stopObservation='SameAliveAfterGuard5s'
                    for($index=0;$index -lt 5;$index++){
                        & $adapter.Delay 1000;$current=& $adapter.GetProcess $Transition.sourcePid $state.Status
                        if($null -eq $current){$stopObservation='ExitedDuringGuard5s';break}
                        if(-not (& $adapter.ProcessMatch $expected $current)){$stopObservation='IdentityChangedDuringGuard5s';break}
                    }
                }
            }
            $ordinary=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter|Where-Object{$_.Mode -ceq 'Ordinary'})
        }
        if($Transition.stage -ceq 'RecoveryLaunchRequested'){
            $candidate=Find-CcodOrdinarySnapshot $state.Status $adapter
            if($null -ne $candidate){$ordinary=@($candidate);$recoveryObservation='OrdinaryAppearedWithin5s'}else{$recoveryObservation='NotStarted'}
        }
        if(@('SpecialLaunchRequested','SpecialStarted','Validated') -ccontains $Transition.stage){
            $specialObservation=Get-CcodStageAwareSpecialObservation $Transition $state $probe $Request $Paths $adapter
        } elseif($adapter.ObserveSpecialIsDefault -and @('RecoveryLaunchRequested','Recovered') -ccontains $Transition.stage -and $null -ne $Transition.specialPid){
            $recorded=& $adapter.GetProcess $Transition.specialPid $state.Status
            if($null -eq $recorded -or $recorded.CreationTimeUtc -cne $Transition.specialCreationTimeUtc){
                $specialObservation=[pscustomobject]@{Outcome='NoCandidate';Snapshot=$null;Candidates=@();ConflictOwners=@();Validation='Indeterminate'}
            } else {
                $validation='Indeterminate'
                if(@('SpecialStarted','Validated') -ccontains $Transition.stage -and (& $adapter.WaitPortClosed $Transition.mainPort (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))){
                    try{
                        Invoke-CcodSessionBridge -Request $Request -Mode Renderer -NodePath $probe.NodePath -Paths $Paths -RendererPort $Transition.rendererPort -MainPort $null -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter|Out-Null;$validation='Valid'
                    }catch{$validation='Indeterminate'}
                }
                $specialObservation=[pscustomobject]@{Outcome='Confirmed';Snapshot=$recorded;Candidates=@($recorded);ConflictOwners=@();Validation=$validation}
            }
        } else {
            $specialObservation=& $adapter.ObserveSpecial $Transition $Paths $Request.timeoutMilliseconds
        }
        $specialFacts=@()
        foreach($candidate in @($specialObservation.Candidates)){
            $evidence=if(@('SpecialStarted','Validated','RecoveryLaunchRequested','Recovered') -ccontains $Transition.stage){'PersistedIdentity'}else{'PreStatusCandidate'}
            $specialFacts+=,[pscustomobject][ordered]@{Process=$candidate;Evidence=$evidence;Validation=$specialObservation.Validation}
        }
        if($specialFacts.Count -eq 0 -and $null -ne $specialObservation.Snapshot){
            $evidence=if(@('SpecialStarted','Validated','RecoveryLaunchRequested','Recovered') -ccontains $Transition.stage){'PersistedIdentity'}else{'PreStatusCandidate'}
            $specialFacts+=,[pscustomobject][ordered]@{Process=$specialObservation.Snapshot;Evidence=$evidence;Validation=$specialObservation.Validation}
        }
        $portObservation=if($null -eq $Transition.mainPort){'NotApplicable'}else{'Indeterminate'}
        $observed=[pscustomobject][ordered]@{StopObservation=$stopObservation;RecoveryObservation=$recoveryObservation;SpecialObservation=$specialObservation.Outcome;PortObservation=$portObservation;SpecialCandidates=@($specialFacts);OrdinaryCandidates=@($ordinary)}
        $decision=Get-CcodReplayDecision -Transition $Transition -Observed $observed
        switch($decision.Action){
            'CancelKeepOrdinary' {
                if($Transition.stage -ceq 'Recovered'){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recovered identity is missing and cannot be cancelled' $Transition}
                & $adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $Transition.transactionId 'Cancelled'|Out-Null
                $result.ok=$true;$result.outcome='NoAction';$result.safeState=if($ordinary.Count -gt 0){'OrdinaryRunning'}else{'NoCodex'};$result.stage='Cancelled';if($ordinary.Count -gt 0){$result.source=ConvertTo-CcodSessionSource $ordinary[0]};return $result
            }
            'AdoptValidatedSpecial' {
                if($Transition.stage -ceq 'SpecialLaunchRequested'){
                    $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'SpecialLaunchRequested' 'SpecialStarted' $decision.AdoptedProcess $null $null $null
                    $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'SpecialStarted' 'Validated' $null $null $null $null
                }elseif($Transition.stage -ceq 'SpecialStarted'){
                    $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'SpecialStarted' 'Validated' $null $null $null $null
                }elseif($Transition.stage -cne 'Validated'){
                    Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Only a Validated transaction may complete Activated' $Transition
                }
                return Complete-CcodActivatedReplay $result $Request $Paths $adapter $probe $decision.AdoptedProcess $specialObservation.Bridge $Transition.transactionId
            }
            'AdoptOrdinaryRecovery' {
                if($Transition.stage -ceq 'Recovered'){
                    if($null -ne $Transition.mainPort){foreach($port in @($Transition.rendererPort,$Transition.mainPort)){if(-not (& $adapter.WaitPortClosed $port (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recovered replay ports are not explicitly refused' $port}}}
                    return Complete-CcodRecoveredReplay $result $Request $Paths $adapter $probe $decision.AdoptedProcess $Transition.transactionId
                }
                return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $Transition.stage $null $Transition.rendererPort $Transition.mainPort $Transition.transactionId
            }
            { @('RecoverOrdinary','TerminateSpecialThenRecover') -ccontains $_ } {
                $special=$null;if($decision.Action -ceq 'TerminateSpecialThenRecover'){$special=$decision.AdoptedProcess}
                return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $Transition.stage $special $Transition.rendererPort $Transition.mainPort $Transition.transactionId
            }
            default {Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' "Replay action $($decision.Action) requires user intervention" $decision}
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-CcodInspectSession','Invoke-CcodCloseSession','Invoke-CcodApplySession','Invoke-CcodRepairStaleSession','Invoke-CcodRepairRenderer',
    'Invoke-CcodRecoverSession','Invoke-CcodReplayTransition','Test-CcodBridgeResult'
)
