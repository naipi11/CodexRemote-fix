[CmdletBinding()]
param(
    [string]$RequestPath,
    [string]$ResultPath,
    [string]$StartupGateName,
    [string]$StartupGateToken,
    [int]$ExpectedParentPid,
    [string]$ExpectedParentCreationTimeUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

if($MyInvocation.InvocationName -ne '.'){
    Import-Module (Join-Path $PSScriptRoot 'modules\WorkerRuntime.psm1') -Force
    [void](Wait-CcodWorkerStartupGate -GateName $StartupGateName -GateToken $StartupGateToken -ExpectedParentPid $ExpectedParentPid -ExpectedParentCreationTimeUtc $ExpectedParentCreationTimeUtc -TimeoutMilliseconds 15000)
}

$script:CcodStaticProbeWorkerScriptPath = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { $null } else { [IO.Path]::GetFullPath($PSCommandPath) }
$script:CcodStaticProbeRequestFields = @('schemaVersion','action','requestId','runtimeId','supervisorIdentity','targetIdentity','timeoutMilliseconds')
$script:CcodStaticProbeResultFields = @('schemaVersion','action','ok','requestId','runtimeId','targetIdentity','probe','error')
$script:CcodStaticProbeFields = @('ready','code','staticClassification','affectedBuildDetected','packageInstalled','packageFullName','packageFamilyName','packageVersion','executablePath','appAsarSha256','nodeVersion','nodeMajor','nodeSupported','nativeModulePresent','signatures')
$script:CcodStaticProbeSignatureFields = @('invertedGate','deviceKeyModuleReference','macOnlyGuard','windowsControllerUi')
$script:CcodStaticProbeErrorFields = @('code','stage','message')
$script:CcodStaticProbeRequiredFiles = @(
    'src/persistence/StaticProbeWorker.ps1',
    'src/persistence/modules/RuntimeManifest.psm1',
    'src/persistence/modules/PersistenceIO.psm1',
    'src/persistence/modules/WorkerRuntime.psm1',
    'src/persistence/modules/TrustedLogonIdentity.psm1',
    'src/persistence/modules/StateStore.psm1',
    'src/persistence/modules/CompatibilityProbe.psm1',
    'src/persistence/modules/ProcessControl.psm1',
    'src/check-package.mjs'
)
$script:CcodStaticProbeErrorCodes = @(
    'CCOD_STATIC_REQUEST_INVALID','CCOD_STATIC_PATH_INVALID','CCOD_STATIC_RUNTIME_UNAUTHORIZED',
    'CCOD_STATIC_MODULE_LOAD_FAILED','CCOD_STATIC_STATE_INVALID','CCOD_STATIC_SUPERVISOR_CHANGED',
    'CCOD_STATIC_TARGET_CHANGED','CCOD_STATIC_PACKAGE_CHANGED','CCOD_STATIC_PROBE_FAILED',
    'CCOD_STATIC_PROBE_TIMEOUT','CCOD_STATIC_RESULT_INVALID'
)
$script:CcodStaticProbeStages = @(
    'InputValidation','RuntimeAuthorization','ModuleLoad','StateRead','SupervisorPreflight','TargetPreflight',
    'StaticProbe','SupervisorPostflight','TargetPostflight','RuntimePostflight','ResultValidation'
)
$script:CcodStaticProbeRuntimeBindings = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)

function Throw-CcodStaticProbeError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodStaticProbeErrorId {
    param($Failure)
    if ($null -ne $Failure -and $Failure.FullyQualifiedErrorId -is [string]) { return ($Failure.FullyQualifiedErrorId -split ',')[0] }
    return $null
}

function Test-CcodStaticAdapterStreamRecord {
    param($Value)
    return $Value -is [Management.Automation.ErrorRecord] -or
        $Value -is [Management.Automation.WarningRecord] -or
        $Value -is [Management.Automation.VerboseRecord] -or
        $Value -is [Management.Automation.DebugRecord] -or
        $Value -is [Management.Automation.InformationRecord]
}

function Invoke-CcodStaticAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Callback,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ArgumentList,
        [Parameter(Mandatory)][ValidateSet('None','Single','OptionalSingle')][string]$OutputMode,
        [Parameter(Mandatory)][string]$ErrorId
    )
    if($Callback -isnot [scriptblock]){Throw-CcodStaticProbeError $ErrorId 'Static probe adapter contract failed' $null}
    try{$emitted=@(& $Callback @ArgumentList *>&1)}catch{
        if($script:CcodStaticProbeErrorCodes -ccontains (Get-CcodStaticProbeErrorId $_)){throw}
        Throw-CcodStaticProbeError $ErrorId 'Static probe adapter invocation failed' $null
    }
    foreach($value in $emitted){if(Test-CcodStaticAdapterStreamRecord $value){Throw-CcodStaticProbeError $ErrorId 'Static probe adapter emitted a diagnostic stream' $null}}
    if(($OutputMode -ceq 'None' -and $emitted.Count -ne 0) -or
        ($OutputMode -ceq 'Single' -and $emitted.Count -ne 1) -or
        ($OutputMode -ceq 'OptionalSingle' -and $emitted.Count -gt 1)){
        Throw-CcodStaticProbeError $ErrorId 'Static probe adapter emitted an unexpected result count' $null
    }
    if($emitted.Count -eq 1){return $emitted[0]}
    return $null
}

function Assert-CcodStaticExactObject {
    param($Value,[string[]]$Fields,[string]$ErrorId,[string]$Kind)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { Throw-CcodStaticProbeError $ErrorId "$Kind must be an exact object" $null }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -ne $Fields.Count) { Throw-CcodStaticProbeError $ErrorId "$Kind has unexpected fields" $null }
    for ($index=0;$index -lt $Fields.Count;$index++) {
        if ($properties[$index].Name -cne $Fields[$index] -or $properties[$index].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty) {
            Throw-CcodStaticProbeError $ErrorId "$Kind has unexpected field order or member type" $null
        }
    }
    return $Value
}

function Test-CcodStaticCanonicalUtc {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodStaticCanonicalGuid {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    $parsed=[guid]::Empty
    return [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodStaticRuntimeId {
    param($Value)
    return $Value -is [string] -and $Value -cmatch '^[A-Za-z0-9._-]{1,96}$'
}

function Test-CcodStaticCanonicalSid {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    try { $sid=[Security.Principal.SecurityIdentifier]::new($Value);return $sid.Value -ceq $Value } catch { return $false }
}

function Test-CcodStaticCanonicalSession {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^(?:0|[1-9][0-9]{0,9})$') { return $false }
    $parsed=0
    return [int]::TryParse($Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed) -and $parsed -ge 0 -and $parsed.ToString([Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Assert-CcodStaticProbeRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    Assert-CcodStaticExactObject $Request $script:CcodStaticProbeRequestFields 'CCOD_STATIC_REQUEST_INVALID' 'Static probe request'|Out-Null
    if ($Request.schemaVersion -isnot [int] -or $Request.schemaVersion -ne 1 -or
        $Request.action -isnot [string] -or $Request.action -cne 'StaticProbe' -or
        -not (Test-CcodStaticCanonicalGuid $Request.requestId) -or
        -not (Test-CcodStaticRuntimeId $Request.runtimeId) -or
        $Request.timeoutMilliseconds -isnot [int] -or $Request.timeoutMilliseconds -lt 500 -or $Request.timeoutMilliseconds -gt 120000) {
        Throw-CcodStaticProbeError 'CCOD_STATIC_REQUEST_INVALID' 'Static probe request scalar fields are invalid' $null
    }
    Assert-CcodStaticExactObject $Request.supervisorIdentity @('pid','creationTimeUtc','sessionId') 'CCOD_STATIC_REQUEST_INVALID' 'Supervisor identity'|Out-Null
    if ($Request.supervisorIdentity.pid -isnot [int] -or $Request.supervisorIdentity.pid -lt 1 -or
        -not (Test-CcodStaticCanonicalUtc $Request.supervisorIdentity.creationTimeUtc) -or
        -not (Test-CcodStaticCanonicalSession $Request.supervisorIdentity.sessionId)) {
        Throw-CcodStaticProbeError 'CCOD_STATIC_REQUEST_INVALID' 'Supervisor identity is invalid' $null
    }
    Assert-CcodStaticExactObject $Request.targetIdentity @('pid','creationTimeUtc') 'CCOD_STATIC_REQUEST_INVALID' 'Target identity'|Out-Null
    if ($Request.targetIdentity.pid -isnot [int] -or $Request.targetIdentity.pid -lt 1 -or -not (Test-CcodStaticCanonicalUtc $Request.targetIdentity.creationTimeUtc)) {
        Throw-CcodStaticProbeError 'CCOD_STATIC_REQUEST_INVALID' 'Target identity is invalid' $null
    }
    return $Request
}

function Copy-CcodStaticTargetIdentity {
    param($Identity)
    if ($null -eq $Identity) { return $null }
    return [pscustomobject][ordered]@{pid=[int]$Identity.pid;creationTimeUtc=[string]$Identity.creationTimeUtc}
}

function New-CcodStaticProbeErrorResult {
    [CmdletBinding()]
    param($Request,[string]$Code,[string]$Stage)
    if ($script:CcodStaticProbeErrorCodes -cnotcontains $Code) { $Code='CCOD_STATIC_PROBE_FAILED' }
    if ($script:CcodStaticProbeStages -cnotcontains $Stage) { $Stage='StaticProbe' }
    $valid=$false
    try { if ($null -ne $Request) { Assert-CcodStaticProbeRequest $Request|Out-Null;$valid=$true } } catch { $valid=$false }
    return [pscustomobject][ordered]@{
        schemaVersion=1
        action='StaticProbe'
        ok=$false
        requestId=$(if($valid){$Request.requestId}else{$null})
        runtimeId=$(if($valid){$Request.runtimeId}else{$null})
        targetIdentity=$(if($valid){Copy-CcodStaticTargetIdentity $Request.targetIdentity}else{$null})
        probe=$null
        error=[pscustomobject][ordered]@{code=$Code;stage=$Stage;message='The static probe worker failed safely.'}
    }
}

function Assert-CcodStaticProbeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result,$ExpectedRequest)
    Assert-CcodStaticExactObject $Result $script:CcodStaticProbeResultFields 'CCOD_STATIC_RESULT_INVALID' 'Static probe result'|Out-Null
    if ($Result.schemaVersion -isnot [int] -or $Result.schemaVersion -ne 1 -or $Result.action -isnot [string] -or $Result.action -cne 'StaticProbe' -or $Result.ok -isnot [bool]) {
        Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe result scalar fields are invalid' $null
    }
    $correlated=$false
    if ($null -ne $ExpectedRequest) { try { Assert-CcodStaticProbeRequest $ExpectedRequest|Out-Null;$correlated=$true } catch { $correlated=$false } }
    if ($correlated) {
        if ($Result.requestId -isnot [string] -or $Result.requestId -cne $ExpectedRequest.requestId -or $Result.runtimeId -isnot [string] -or $Result.runtimeId -cne $ExpectedRequest.runtimeId) {
            Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe result correlation is invalid' $null
        }
        Assert-CcodStaticExactObject $Result.targetIdentity @('pid','creationTimeUtc') 'CCOD_STATIC_RESULT_INVALID' 'Result target identity'|Out-Null
        if ($Result.targetIdentity.pid -isnot [int] -or $Result.targetIdentity.pid -ne $ExpectedRequest.targetIdentity.pid -or $Result.targetIdentity.creationTimeUtc -isnot [string] -or $Result.targetIdentity.creationTimeUtc -cne $ExpectedRequest.targetIdentity.creationTimeUtc) {
            Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe target correlation is invalid' $null
        }
    } elseif ($null -ne $Result.requestId -or $null -ne $Result.runtimeId -or $null -ne $Result.targetIdentity) {
        Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Invalid requests cannot retain correlation' $null
    }
    if (-not $Result.ok) {
        if ($null -ne $Result.probe) { Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Failed static probe result cannot contain probe evidence' $null }
        Assert-CcodStaticExactObject $Result.error $script:CcodStaticProbeErrorFields 'CCOD_STATIC_RESULT_INVALID' 'Static probe error'|Out-Null
        if ($Result.error.code -isnot [string] -or $script:CcodStaticProbeErrorCodes -cnotcontains $Result.error.code -or
            $Result.error.stage -isnot [string] -or $script:CcodStaticProbeStages -cnotcontains $Result.error.stage -or
            $Result.error.message -isnot [string] -or $Result.error.message -cne 'The static probe worker failed safely.') {
            Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe error is not sanitized' $null
        }
        return $Result
    }
    if (-not $correlated -or $null -ne $Result.error) { Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Successful static probe result must be correlated and error-free' $null }
    Assert-CcodStaticExactObject $Result.probe $script:CcodStaticProbeFields 'CCOD_STATIC_RESULT_INVALID' 'Static probe evidence'|Out-Null
    $probe=$Result.probe
    if ($probe.ready -isnot [bool] -or $probe.code -isnot [string] -or $probe.code -cne 'CHECKER_OK' -or
        $probe.staticClassification -isnot [string] -or @('CandidateCompatible','NativeModulePresent','UnknownOrIncompatible') -cnotcontains $probe.staticClassification -or
        $probe.packageInstalled -isnot [bool] -or -not $probe.packageInstalled -or $probe.nodeSupported -isnot [bool] -or -not $probe.nodeSupported -or
        $probe.affectedBuildDetected -isnot [bool] -or $probe.nativeModulePresent -isnot [bool]) { Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe evidence flags are invalid' $null }
    Assert-CcodStaticExactObject $probe.signatures $script:CcodStaticProbeSignatureFields 'CCOD_STATIC_RESULT_INVALID' 'Static probe signatures'|Out-Null
    foreach($name in $script:CcodStaticProbeSignatureFields){
        if($probe.signatures.$name -isnot [bool]){Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe signatures are invalid' $null}
    }
    foreach ($name in @('packageFullName','packageFamilyName','packageVersion','executablePath','appAsarSha256','nodeVersion')) {
        if ($probe.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($probe.$name) -or $probe.$name -match '[\r\n]') { Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe string evidence is invalid' $null }
    }
    $path=$null;try{$path=[IO.Path]::GetFullPath($probe.executablePath)}catch{}
    $allSentinels=@($script:CcodStaticProbeSignatureFields|Where-Object{-not $probe.signatures.$_}).Count -eq 0
    $validTuple=(
        ($probe.staticClassification -ceq 'CandidateCompatible' -and $probe.ready -and $probe.affectedBuildDetected -and $allSentinels) -or
        ($probe.staticClassification -ceq 'NativeModulePresent' -and -not $probe.ready -and -not $probe.affectedBuildDetected -and $probe.nativeModulePresent -and -not $allSentinels) -or
        ($probe.staticClassification -ceq 'UnknownOrIncompatible' -and -not $probe.ready -and -not $probe.affectedBuildDetected -and -not $probe.nativeModulePresent -and -not $allSentinels)
    )
    if ($null -eq $path -or -not [IO.Path]::IsPathRooted($probe.executablePath) -or $path -cne $probe.executablePath -or
        $probe.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or $probe.nodeMajor -isnot [int] -or $probe.nodeMajor -lt 22 -or
        $probe.nodeVersion -cnotmatch '^v(?<major>[0-9]+)\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$' -or [int]$Matches.major -ne $probe.nodeMajor -or
        -not $validTuple) {
        Throw-CcodStaticProbeError 'CCOD_STATIC_RESULT_INVALID' 'Static probe evidence invariants are invalid' $null
    }
    return $Result
}

function Get-CcodStaticProbePathAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        GetItem={
            param($Path,[bool]$AllowMissing)
            try{return Get-Item -LiteralPath $Path -Force -ErrorAction Stop}
            catch [Management.Automation.ItemNotFoundException]{if($AllowMissing){return $null};throw}
        }
        FileExists={param($Path)[IO.File]::Exists($Path)}
        DirectoryExists={param($Path)[IO.Directory]::Exists($Path)}
    }
    if($null -ne $Adapters){foreach($key in @('GetItem','FileExists','DirectoryExists')){if($Adapters.ContainsKey($key)){$resolved[$key]=$Adapters[$key]}}}
    return $resolved
}

function Assert-CcodStaticProbeNoReparse {
    param([string]$Root,[string]$Path,[switch]$AllowMissingLeaf,[hashtable]$Adapters)
    $adapter=Get-CcodStaticProbePathAdapters $Adapters
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull=[IO.Path]::GetFullPath($Path)
    if($pathFull -cne $rootFull -and -not $pathFull.StartsWith($rootFull+'\',[StringComparison]::OrdinalIgnoreCase)){Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Path is outside the authorized root' $null}
    $cursor=$rootFull;$segments=@()
    if($pathFull.Length -gt $rootFull.Length){$segments=@($pathFull.Substring($rootFull.Length).TrimStart('\') -split '\\')}
    foreach($segment in @('')+$segments){
        if($segment -ne ''){$cursor=Join-Path $cursor $segment}
        $missingLeafAllowed=[bool]($AllowMissingLeaf -and $cursor -ceq $pathFull)
        try{$item=Invoke-CcodStaticAdapter $adapter.GetItem @($cursor,$missingLeafAllowed) OptionalSingle 'CCOD_STATIC_PATH_INVALID'}catch{Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Required path is missing' $null}
        if($null -eq $item){if($missingLeafAllowed){return};Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Required path is missing' $null}
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Reparse path is not authorized' $null}
        if($missingLeafAllowed){Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'The result path already exists' $null}
    }
}

function Assert-CcodStaticProbeFramingPaths {
    param($Context,[string]$RequestPath,[string]$ResultPath,$Request,[switch]$RequireCorrelation,[hashtable]$Adapters)
    $adapter=Get-CcodStaticProbePathAdapters $Adapters
    if($null -eq $Context -or $Context.WorkersRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($RequestPath) -or [string]::IsNullOrWhiteSpace($ResultPath)){
        Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Worker framing paths are invalid' $null
    }
    $workers=[IO.Path]::GetFullPath($Context.WorkersRoot)
    foreach($path in @($RequestPath,$ResultPath)){
        $full=$null;try{$full=[IO.Path]::GetFullPath($path)}catch{}
        if($null -eq $full -or -not [IO.Path]::IsPathRooted($path) -or $full -cne $path -or (Split-Path $full -Parent) -cne $workers){Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Worker framing paths must be canonical direct children' $null}
    }
    $workersExists=Invoke-CcodStaticAdapter $adapter.DirectoryExists @($workers) Single 'CCOD_STATIC_PATH_INVALID'
    $requestExists=Invoke-CcodStaticAdapter $adapter.FileExists @($RequestPath) Single 'CCOD_STATIC_PATH_INVALID'
    $resultExists=Invoke-CcodStaticAdapter $adapter.FileExists @($ResultPath) Single 'CCOD_STATIC_PATH_INVALID'
    if($workersExists -isnot [bool] -or $requestExists -isnot [bool] -or $resultExists -isnot [bool] -or $RequestPath -ceq $ResultPath -or -not $workersExists -or -not $requestExists -or $resultExists){
        Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Worker framing path state is invalid' $null
    }
    Assert-CcodStaticProbeNoReparse -Root $Context.InstallRoot -Path $workers -Adapters $adapter
    Assert-CcodStaticProbeNoReparse -Root $Context.InstallRoot -Path $RequestPath -Adapters $adapter
    Assert-CcodStaticProbeNoReparse -Root $Context.InstallRoot -Path $ResultPath -AllowMissingLeaf -Adapters $adapter
    $requestLeaf=[IO.Path]::GetFileName($RequestPath);$resultLeaf=[IO.Path]::GetFileName($ResultPath)
    if($requestLeaf -cnotmatch '^static-probe-[0-9a-f-]{36}\.request\.json$' -or $resultLeaf -cnotmatch '^static-probe-[0-9a-f-]{36}\.result\.json$'){
        Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Worker framing filenames are invalid' $null
    }
    if($RequireCorrelation){
        Assert-CcodStaticProbeRequest $Request|Out-Null
        if($requestLeaf -cne "static-probe-$($Request.requestId).request.json" -or $resultLeaf -cne "static-probe-$($Request.requestId).result.json"){
            Throw-CcodStaticProbeError 'CCOD_STATIC_PATH_INVALID' 'Worker framing filenames do not match the request' $null
        }
    }
}

function Skip-CcodStaticJsonWhitespace {
    param([string]$Text,[ref]$Index)
    while($Index.Value -lt $Text.Length -and ($Text[$Index.Value] -eq ' ' -or $Text[$Index.Value] -eq "`t" -or $Text[$Index.Value] -eq "`r" -or $Text[$Index.Value] -eq "`n")){$Index.Value++}
}

function Read-CcodStaticJsonStringToken {
    param([string]$Text,[ref]$Index)
    if($Index.Value -ge $Text.Length -or $Text[$Index.Value] -ne '"'){throw 'json string'}
    $start=$Index.Value;$Index.Value++
    while($Index.Value -lt $Text.Length){
        $character=$Text[$Index.Value]
        if($character -eq '"'){$Index.Value++;return $Text.Substring($start,$Index.Value-$start)}
        if([int][char]$character -lt 0x20){throw 'json control character'}
        if($character -eq '\'){
            $Index.Value++;if($Index.Value -ge $Text.Length){throw 'json escape'}
            $escape=$Text[$Index.Value]
            if($escape -eq 'u'){
                if($Index.Value+4 -ge $Text.Length -or $Text.Substring($Index.Value+1,4) -cnotmatch '^[0-9A-Fa-f]{4}$'){throw 'json unicode escape'}
                $Index.Value+=5;continue
            }
            if('"\/bfnrt'.IndexOf($escape) -lt 0){throw 'json escape'}
        }
        $Index.Value++
    }
    throw 'unterminated json string'
}

function Read-CcodStaticJsonValue {
    param([string]$Text,[ref]$Index)
    Skip-CcodStaticJsonWhitespace $Text $Index
    if($Index.Value -ge $Text.Length){throw 'json value'}
    if($Text[$Index.Value] -eq '{'){
        $Index.Value++;Skip-CcodStaticJsonWhitespace $Text $Index
        $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if($Index.Value -lt $Text.Length -and $Text[$Index.Value] -eq '}'){$Index.Value++;return}
        while($true){
            $encoded=Read-CcodStaticJsonStringToken $Text $Index
            $key=$encoded|ConvertFrom-Json -ErrorAction Stop
            if($key -isnot [string] -or -not $keys.Add($key)){throw 'duplicate json object key'}
            Skip-CcodStaticJsonWhitespace $Text $Index
            if($Index.Value -ge $Text.Length -or $Text[$Index.Value] -ne ':'){throw 'json object separator'}
            $Index.Value++;Read-CcodStaticJsonValue $Text $Index
            Skip-CcodStaticJsonWhitespace $Text $Index
            if($Index.Value -ge $Text.Length){throw 'json object end'}
            if($Text[$Index.Value] -eq '}'){$Index.Value++;return}
            if($Text[$Index.Value] -ne ','){throw 'json object delimiter'}
            $Index.Value++;Skip-CcodStaticJsonWhitespace $Text $Index
        }
    }
    if($Text[$Index.Value] -eq '['){
        $Index.Value++;Skip-CcodStaticJsonWhitespace $Text $Index
        if($Index.Value -lt $Text.Length -and $Text[$Index.Value] -eq ']'){$Index.Value++;return}
        while($true){
            Read-CcodStaticJsonValue $Text $Index;Skip-CcodStaticJsonWhitespace $Text $Index
            if($Index.Value -ge $Text.Length){throw 'json array end'}
            if($Text[$Index.Value] -eq ']'){$Index.Value++;return}
            if($Text[$Index.Value] -ne ','){throw 'json array delimiter'}
            $Index.Value++
        }
    }
    if($Text[$Index.Value] -eq '"'){[void](Read-CcodStaticJsonStringToken $Text $Index);return}
    $start=$Index.Value
    while($Index.Value -lt $Text.Length -and $Text[$Index.Value] -ne ',' -and $Text[$Index.Value] -ne ']' -and $Text[$Index.Value] -ne '}' -and
        $Text[$Index.Value] -ne ' ' -and $Text[$Index.Value] -ne "`t" -and $Text[$Index.Value] -ne "`r" -and $Text[$Index.Value] -ne "`n"){$Index.Value++}
    if($Index.Value -eq $start){throw 'json scalar'}
}

function Assert-CcodStaticJsonNoDuplicateKeys {
    param([string]$Text)
    $index=0;Read-CcodStaticJsonValue $Text ([ref]$index);Skip-CcodStaticJsonWhitespace $Text ([ref]$index)
    if($index -ne $Text.Length){throw 'json trailing content'}
}

function Read-CcodStaticProbeLocalJson {
    param([string]$Path,[string]$ErrorId='CCOD_STATIC_RUNTIME_UNAUTHORIZED')
    try{
        $text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($Path))
        Assert-CcodStaticJsonNoDuplicateKeys $text
        $value=$text|ConvertFrom-Json -ErrorAction Stop
    }catch{Throw-CcodStaticProbeError $ErrorId 'Strict JSON input is invalid' $null}
    if($null -eq $value -or $value -isnot [pscustomobject]){Throw-CcodStaticProbeError $ErrorId 'Strict JSON root is invalid' $null}
    return $value
}

function Write-CcodStaticProbeLocalAtomicJson {
    param([string]$Path,$Value)
    $directory=Split-Path $Path -Parent;$leaf=[IO.Path]::GetFileName($Path)
    $temporary=[IO.Path]::GetFullPath((Join-Path $directory ('.{0}.{1}.tmp' -f $leaf,[guid]::NewGuid().ToString('N'))))
    $stream=$null
    try{
        if([IO.File]::Exists($Path)){throw 'result already exists'}
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20)+"`n")
        $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
        if([IO.File]::Exists($Path)){throw 'result appeared before commit'}
        [IO.File]::Move($temporary,$Path)
    }finally{
        if($null -ne $stream){try{$stream.Dispose()}catch{}}
        if([IO.File]::Exists($temporary)){try{[IO.File]::Delete($temporary)}catch{}}
    }
}

function Test-CcodStaticProbeRequestMatch {
    param($Left,$Right)
    try{Assert-CcodStaticProbeRequest $Left|Out-Null;Assert-CcodStaticProbeRequest $Right|Out-Null}catch{return $false}
    return $Left.schemaVersion -eq $Right.schemaVersion -and $Left.action -ceq $Right.action -and $Left.requestId -ceq $Right.requestId -and
        $Left.runtimeId -ceq $Right.runtimeId -and $Left.timeoutMilliseconds -eq $Right.timeoutMilliseconds -and
        $Left.supervisorIdentity.pid -eq $Right.supervisorIdentity.pid -and $Left.supervisorIdentity.creationTimeUtc -ceq $Right.supervisorIdentity.creationTimeUtc -and
        $Left.supervisorIdentity.sessionId -ceq $Right.supervisorIdentity.sessionId -and $Left.targetIdentity.pid -eq $Right.targetIdentity.pid -and
        $Left.targetIdentity.creationTimeUtc -ceq $Right.targetIdentity.creationTimeUtc
}

function Test-CcodStaticManifestPath {
    param($Value)
    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) -and -not [IO.Path]::IsPathRooted($Value) -and
        -not $Value.StartsWith('/') -and $Value.IndexOf('\') -lt 0 -and $Value.IndexOf(':') -lt 0 -and $Value -notmatch '(^|/)(?:\.|\.\.)(?:/|$)' -and
        -not $Value.Contains('//') -and $Value -notmatch '[\x00-\x1f]' -and -not $Value.Equals('manifest.json',[StringComparison]::OrdinalIgnoreCase)
}

function Get-CcodStaticRuntimeIdFromRecords {
    param([string]$ProjectVersion,[object[]]$Files)
    $lines=[Collections.Generic.List[string]]::new()
    foreach($file in $Files){$lines.Add(('{0}`t{1}`t{2}' -f [string]$file.path,[int64]$file.length,[string]$file.sha256))}
    $canonical=$lines -join "`n";$sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $runtimeId='{0}-{1}' -f $ProjectVersion,$digest.Substring(0,16)
    if(-not (Test-CcodStaticRuntimeId $runtimeId)){Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'Computed runtime ID is invalid' $null}
    return $runtimeId
}

function Get-CcodStaticFileSha256 {
    param([string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $stream=[IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        try{
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
        }finally{$stream.Dispose()}
    }finally{$sha.Dispose()}
}

function Get-CcodStaticProbeRuntimeAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath,[hashtable]$Adapters)
    try{
        if([string]::IsNullOrWhiteSpace($ScriptPath) -or -not [IO.Path]::IsPathRooted($ScriptPath) -or [IO.Path]::GetFullPath($ScriptPath) -cne $ScriptPath -or [IO.Path]::GetFileName($ScriptPath) -cne 'StaticProbeWorker.ps1') { throw 'self path' }
        $persistenceRoot=Split-Path $ScriptPath -Parent;$srcRoot=Split-Path $persistenceRoot -Parent;$runtimeRoot=Split-Path $srcRoot -Parent
        $runtimeContainer=Split-Path $runtimeRoot -Parent;$installRoot=Split-Path $runtimeContainer -Parent;$runtimeId=Split-Path $runtimeRoot -Leaf
        if((Split-Path $persistenceRoot -Leaf) -cne 'persistence' -or (Split-Path $srcRoot -Leaf) -cne 'src' -or (Split-Path $runtimeContainer -Leaf) -cne 'runtime' -or -not (Test-CcodStaticRuntimeId $runtimeId)){throw 'layout'}
        $installRoot=[IO.Path]::GetFullPath($installRoot);$runtimeRoot=[IO.Path]::GetFullPath($runtimeRoot)
        Assert-CcodStaticProbeNoReparse -Root $installRoot -Path $ScriptPath -Adapters $Adapters
        $activePath=[IO.Path]::GetFullPath((Join-Path $installRoot 'active.json'));Assert-CcodStaticProbeNoReparse $installRoot $activePath -Adapters $Adapters
        $active=Read-CcodStaticProbeLocalJson $activePath;Assert-CcodStaticExactObject $active @('schemaVersion','activeRuntime','previousRuntime','updatedAtUtc') 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'Active pointer'|Out-Null
        if($active.schemaVersion -isnot [int] -or $active.schemaVersion -ne 1 -or -not(Test-CcodStaticRuntimeId $active.activeRuntime) -or
            ($null -ne $active.previousRuntime -and (-not(Test-CcodStaticRuntimeId $active.previousRuntime) -or $active.previousRuntime -ceq $active.activeRuntime)) -or
            -not(Test-CcodStaticCanonicalUtc $active.updatedAtUtc) -or $active.activeRuntime -cne $runtimeId){throw 'active pointer'}
        $expectedRuntime=[IO.Path]::GetFullPath((Join-Path (Join-Path $installRoot 'runtime') $active.activeRuntime))
        $expectedWorker=[IO.Path]::GetFullPath((Join-Path $expectedRuntime 'src\persistence\StaticProbeWorker.ps1'))
        if($expectedRuntime -cne $runtimeRoot -or $expectedWorker -cne $ScriptPath){throw 'self binding'}
        $manifestPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'manifest.json'));Assert-CcodStaticProbeNoReparse $installRoot $manifestPath -Adapters $Adapters
        $manifest=Read-CcodStaticProbeLocalJson $manifestPath;Assert-CcodStaticExactObject $manifest @('schemaVersion','projectVersion','runtimeId','files') 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'Runtime manifest'|Out-Null
        if($manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -ne 1 -or $manifest.projectVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.projectVersion) -or
            -not(Test-CcodStaticRuntimeId $manifest.runtimeId) -or $manifest.files -isnot [array]){throw 'manifest root'}
        $records=[Collections.Generic.List[object]]::new();$previous=$null
        foreach($file in @($manifest.files)){
            Assert-CcodStaticExactObject $file @('path','length','sha256') 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'Manifest file record'|Out-Null
            if(-not(Test-CcodStaticManifestPath $file.path) -or ($file.length -isnot [int] -and $file.length -isnot [long]) -or $file.length -lt 0 -or
                $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$file.path) -ge 0)){throw 'manifest record'}
            $previous=$file.path;$records.Add([pscustomobject][ordered]@{path=$file.path;length=[int64]$file.length;sha256=$file.sha256})
        }
        foreach($required in $script:CcodStaticProbeRequiredFiles){if(@($records|Where-Object{$_.path -ceq $required}).Count -ne 1){throw 'required file'}}
        $computed=Get-CcodStaticRuntimeIdFromRecords $manifest.projectVersion $records.ToArray()
        if($computed -cne $manifest.runtimeId -or $computed -cne $active.activeRuntime -or $computed -cne $runtimeId){throw 'runtime id'}
        foreach($required in $script:CcodStaticProbeRequiredFiles){
            $record=@($records|Where-Object{$_.path -ceq $required})[0];$path=[IO.Path]::GetFullPath((Join-Path $runtimeRoot ($required.Replace('/','\'))))
            if(-not $path.StartsWith($runtimeRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'required containment'}
            Assert-CcodStaticProbeNoReparse $installRoot $path -Adapters $Adapters
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if($item.PSIsContainer -or [int64]$item.Length -ne $record.length -or (Get-CcodStaticFileSha256 $path) -cne $record.sha256){throw 'required hash'}
        }
        $activeHash=Get-CcodStaticFileSha256 $activePath;$manifestHash=Get-CcodStaticFileSha256 $manifestPath
        $stateRoot=[IO.Path]::GetFullPath((Join-Path $installRoot 'state'));$workersRoot=[IO.Path]::GetFullPath((Join-Path $stateRoot 'workers'))
        return [pscustomobject][ordered]@{
            InstallRoot=$installRoot;RuntimeRoot=$runtimeRoot;RuntimeId=$runtimeId;WorkerPath=$ScriptPath;StateRoot=$stateRoot;WorkersRoot=$workersRoot
            CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\check-package.mjs'));AuthorizationId="$activeHash|$manifestHash|$runtimeId"
        }
    }catch{
        if((Get-CcodStaticProbeErrorId $_) -ceq 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'){throw}
        Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'The static probe worker is not the exact active verified runtime' $null
    }
}

function Invoke-CcodStaticProbeRuntimeBinding {
    param([string]$BindingId,[string]$Name,[object[]]$ArgumentList)
    if(-not $script:CcodStaticProbeRuntimeBindings.ContainsKey($BindingId)){
        Throw-CcodStaticProbeError 'CCOD_STATIC_MODULE_LOAD_FAILED' 'The verified runtime facade is unavailable' $null
    }
    $binding=$script:CcodStaticProbeRuntimeBindings[$BindingId]
    if($null -eq $binding -or -not $binding.Contains($Name)){Throw-CcodStaticProbeError 'CCOD_STATIC_MODULE_LOAD_FAILED' 'The verified runtime facade operation is unavailable' $null}
    $callback=$binding[$Name]
    if($callback -isnot [scriptblock]){Throw-CcodStaticProbeError 'CCOD_STATIC_MODULE_LOAD_FAILED' 'The verified runtime facade is invalid' $null}
    return & $callback @ArgumentList
}

function New-CcodStaticProbeRuntimeFacade {
    param([string]$BindingId)
    if($BindingId -cnotmatch '^[0-9a-f]{32}$'){Throw-CcodStaticProbeError 'CCOD_STATIC_MODULE_LOAD_FAILED' 'The verified runtime facade identity is invalid' $null}
    return [pscustomobject][ordered]@{
        TestRuntimeManifest=[scriptblock]::Create("param(`$RuntimeDirectory,`$ExpectedRuntimeId);Invoke-CcodStaticProbeRuntimeBinding '$BindingId' 'TestRuntimeManifest' ([object[]]@(`$RuntimeDirectory,`$ExpectedRuntimeId))")
        ReadStrictJson=[scriptblock]::Create("param(`$Path,`$ExpectedSchema,`$Kind);Invoke-CcodStaticProbeRuntimeBinding '$BindingId' 'ReadStrictJson' ([object[]]@(`$Path,`$ExpectedSchema,`$Kind))")
        ReadSettings=[scriptblock]::Create("param(`$StateRoot);Invoke-CcodStaticProbeRuntimeBinding '$BindingId' 'ReadSettings' ([object[]]@(`$StateRoot))")
        GetPackageIdentity=[scriptblock]::Create("param();Invoke-CcodStaticProbeRuntimeBinding '$BindingId' 'GetPackageIdentity' ([object[]]@())")
        InvokeStaticProbe=[scriptblock]::Create("param([string[]]`$NodeCandidates,`$CheckerPath,`$Adapters);`$arguments=[object[]]::new(3);`$arguments[0]=`$NodeCandidates;`$arguments[1]=`$CheckerPath;`$arguments[2]=`$Adapters;Invoke-CcodStaticProbeRuntimeBinding '$BindingId' 'InvokeStaticProbe' `$arguments")
        GetProcessSnapshot=[scriptblock]::Create("param(`$ProcessId,`$StatusEvidence,`$Adapters);`$arguments=[object[]]::new(3);`$arguments[0]=`$ProcessId;`$arguments[1]=`$StatusEvidence;`$arguments[2]=`$Adapters;Invoke-CcodStaticProbeRuntimeBinding '$BindingId' 'GetProcessSnapshot' `$arguments")
    }
}

function Import-CcodStaticProbeRuntime {
    param($Context)
    $modulePaths=[pscustomobject][ordered]@{
        RuntimeManifest=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\persistence\modules\RuntimeManifest.psm1'))
        PersistenceIO=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\persistence\modules\PersistenceIO.psm1'))
        StateStore=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\persistence\modules\StateStore.psm1'))
        CompatibilityProbe=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\persistence\modules\CompatibilityProbe.psm1'))
        ProcessControl=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\persistence\modules\ProcessControl.psm1'))
    }
    $bindings=[ordered]@{};$bindingId=$null;$registered=$false
    try{
        foreach($specification in @(
            [pscustomobject]@{Name='RuntimeManifest';Exports=[ordered]@{TestRuntimeManifest='Test-CcodRuntimeManifest'}},
            [pscustomobject]@{Name='PersistenceIO';Exports=[ordered]@{ReadStrictJson='Read-CcodStrictJson'}},
            [pscustomobject]@{Name='StateStore';Exports=[ordered]@{ReadSettings='Read-CcodSettings'}},
            [pscustomobject]@{Name='CompatibilityProbe';Exports=[ordered]@{GetPackageIdentity='Get-CcodPackageIdentity';InvokeStaticProbe='Invoke-CcodStaticProbe'}},
            [pscustomobject]@{Name='ProcessControl';Exports=[ordered]@{GetProcessSnapshot='Get-CcodProcessSnapshot'}}
        )){
            $expectedPath=[string]$modulePaths.($specification.Name)
            $loaded=@(Import-Module -Name $expectedPath -PassThru -Force -Scope Local -ErrorAction Stop)
            if($loaded.Count -ne 1 -or [IO.Path]::GetFullPath($loaded[0].Path) -cne $expectedPath){throw 'module path'}
            foreach($entry in $specification.Exports.GetEnumerator()){
                $command=$loaded[0].ExportedFunctions[[string]$entry.Value]
                if($null -eq $command -or $command -isnot [Management.Automation.FunctionInfo] -or $command.ScriptBlock -isnot [scriptblock] -or
                    $null -eq $command.Module -or [IO.Path]::GetFullPath($command.Module.Path) -cne $expectedPath){throw 'module export'}
                $bindings[[string]$entry.Key]=$command.ScriptBlock
            }
        }
        $bindingId=[guid]::NewGuid().ToString('N');$script:CcodStaticProbeRuntimeBindings.Add($bindingId,$bindings);$registered=$true
        $facade=New-CcodStaticProbeRuntimeFacade $bindingId
        return [pscustomobject][ordered]@{
            TestRuntimeManifest=$facade.TestRuntimeManifest;ReadStrictJson=$facade.ReadStrictJson;ReadSettings=$facade.ReadSettings
            GetPackageIdentity=$facade.GetPackageIdentity;InvokeStaticProbe=$facade.InvokeStaticProbe;GetProcessSnapshot=$facade.GetProcessSnapshot;ModulePaths=$modulePaths
        }
    }catch{
        if($registered){[void]$script:CcodStaticProbeRuntimeBindings.Remove($bindingId);$registered=$false}
        Throw-CcodStaticProbeError 'CCOD_STATIC_MODULE_LOAD_FAILED' 'Verified runtime modules could not be loaded' $null
    }finally{
        $unloadFailed=$false
        foreach($path in @($modulePaths.PSObject.Properties.Value)){
            foreach($module in @(Get-Module -All|Where-Object{$_.Path -is [string] -and $_.Path -ceq $path})){
                try{Remove-Module -ModuleInfo $module -Force -ErrorAction Stop}catch{$unloadFailed=$true}
            }
            if(@(Get-Module -All|Where-Object{$_.Path -is [string] -and $_.Path -ceq $path}).Count -ne 0){$unloadFailed=$true}
        }
        if($unloadFailed){if($registered){[void]$script:CcodStaticProbeRuntimeBindings.Remove($bindingId)};Throw-CcodStaticProbeError 'CCOD_STATIC_MODULE_LOAD_FAILED' 'Verified runtime modules could not be isolated' $null}
    }
}

function Complete-CcodStaticProbeRuntimeAuthorization {
    param($Context,$RuntimeApi)
    if($null -eq $RuntimeApi -or $RuntimeApi.TestRuntimeManifest -isnot [scriptblock]){Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'The private runtime API is invalid' $null}
    try{$validation=Invoke-CcodStaticAdapter $RuntimeApi.TestRuntimeManifest @($Context.RuntimeRoot,$Context.RuntimeId) Single 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'}catch{Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'The complete runtime could not be verified' $null}
    if($null -eq $validation -or $validation.Valid -isnot [bool] -or -not $validation.Valid -or $validation.RuntimeId -cne $Context.RuntimeId){Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'The complete runtime is not authorized' $null}
    return $Context
}

function Test-CcodStaticAuthorizationMatch {
    param($Before,$After)
    if($null -eq $Before -or $null -eq $After){return $false}
    foreach($name in @('InstallRoot','RuntimeRoot','RuntimeId','WorkerPath','StateRoot','WorkersRoot','CheckerPath','AuthorizationId')){if($Before.$name -isnot [string] -or $After.$name -isnot [string] -or $Before.$name -cne $After.$name){return $false}}
    return $true
}

function Get-CcodStaticCurrentIdentity {
    $identity=$null;$process=$null
    try{$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess();return [pscustomobject][ordered]@{Pid=[int]$process.Id;UserSid=$identity.User.Value;SessionId=[int]$process.SessionId}}
    finally{if($null -ne $process){$process.Dispose()};if($null -ne $identity){$identity.Dispose()}}
}

function Get-CcodStaticParentProcessId {
    $process=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
    if($null -eq $process -or $process.ParentProcessId -isnot [uint32] -and $process.ParentProcessId -isnot [int] -and $process.ParentProcessId -isnot [long]){return $null}
    return [int]$process.ParentProcessId
}

function Get-CcodStaticGenericProcessIdentity {
    param([int]$ProcessId)
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById($ProcessId);$created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$session=[int]$process.SessionId
        $cim=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if($null -eq $cim){return $null};$owner=Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop
        if($null -eq $owner -or $owner.ReturnValue -ne 0 -or $owner.Sid -isnot [string]){return $null}
        $again=[Diagnostics.Process]::GetProcessById($ProcessId);try{$againCreated=$again.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}finally{$again.Dispose()}
        if($againCreated -cne $created){return $null}
        return [pscustomobject][ordered]@{Pid=[int]$ProcessId;CreationTimeUtc=$created;SessionId=$session;UserSid=$owner.Sid}
    }catch{return $null}finally{if($null -ne $process){$process.Dispose()}}
}

function Assert-CcodStaticCurrentIdentity {
    param($Identity,$Request)
    Assert-CcodStaticExactObject $Identity @('Pid','UserSid','SessionId') 'CCOD_STATIC_SUPERVISOR_CHANGED' 'Current worker identity'|Out-Null
    if($Identity.Pid -isnot [int] -or $Identity.Pid -lt 1 -or -not(Test-CcodStaticCanonicalSid $Identity.UserSid) -or $Identity.SessionId -isnot [int] -or $Identity.SessionId -lt 0 -or
        $Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture) -cne $Request.supervisorIdentity.sessionId){Throw-CcodStaticProbeError 'CCOD_STATIC_SUPERVISOR_CHANGED' 'Current worker identity does not match the request session' $null}
    return $Identity
}

function Assert-CcodStaticSupervisorIdentity {
    param($Identity,[int]$ParentPid,$Request,$Current)
    Assert-CcodStaticExactObject $Identity @('Pid','CreationTimeUtc','SessionId','UserSid') 'CCOD_STATIC_SUPERVISOR_CHANGED' 'Supervisor process identity'|Out-Null
    if($ParentPid -ne $Request.supervisorIdentity.pid -or $Identity.Pid -isnot [int] -or $Identity.Pid -ne $Request.supervisorIdentity.pid -or
        $Identity.CreationTimeUtc -isnot [string] -or $Identity.CreationTimeUtc -cne $Request.supervisorIdentity.creationTimeUtc -or
        $Identity.SessionId -isnot [int] -or $Identity.SessionId -ne $Current.SessionId -or $Identity.UserSid -isnot [string] -or $Identity.UserSid -cne $Current.UserSid){
        Throw-CcodStaticProbeError 'CCOD_STATIC_SUPERVISOR_CHANGED' 'The requesting supervisor parent identity changed' $null
    }
    return $Identity
}

function Assert-CcodStaticPackageIdentity {
    param($Package)
    if($null -eq $Package -or $Package.Found -isnot [bool] -or -not $Package.Found){Throw-CcodStaticProbeError 'CCOD_STATIC_PACKAGE_CHANGED' 'The current package identity is unavailable' $null}
    foreach($name in @('FullName','FamilyName','Version','ExecutablePath')){if($null -eq $Package.PSObject.Properties[$name] -or $Package.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Package.$name) -or $Package.$name -match '[\r\n]'){Throw-CcodStaticProbeError 'CCOD_STATIC_PACKAGE_CHANGED' 'The current package identity is invalid' $null}}
    $full=$null;try{$full=[IO.Path]::GetFullPath($Package.ExecutablePath)}catch{}
    if($null -eq $full -or $full -cne $Package.ExecutablePath -or -not[IO.Path]::IsPathRooted($Package.ExecutablePath)){Throw-CcodStaticProbeError 'CCOD_STATIC_PACKAGE_CHANGED' 'The package executable path is invalid' $null}
    return $Package
}

function Assert-CcodStaticTargetSnapshot {
    param($Snapshot,$Request,$Current,$Package)
    Assert-CcodStaticExactObject $Snapshot @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort') 'CCOD_STATIC_TARGET_CHANGED' 'Target process snapshot'|Out-Null
    if($Snapshot.Pid -isnot [int] -or $Snapshot.Pid -ne $Request.targetIdentity.pid -or $Snapshot.CreationTimeUtc -isnot [string] -or $Snapshot.CreationTimeUtc -cne $Request.targetIdentity.creationTimeUtc -or
        $Snapshot.SessionId -isnot [int] -or $Snapshot.SessionId -ne $Current.SessionId -or $Snapshot.UserSid -isnot [string] -or $Snapshot.UserSid -cne $Current.UserSid -or
        $Snapshot.Path -isnot [string] -or -not $Snapshot.Path.Equals($Package.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $Snapshot.PackageFamilyName -isnot [string] -or $Snapshot.PackageFamilyName -cne $Package.FamilyName -or
        $Snapshot.IsTopLevel -isnot [bool] -or -not $Snapshot.IsTopLevel -or $Snapshot.Mode -isnot [string] -or $Snapshot.Mode -cne 'Ordinary' -or $null -ne $Snapshot.RendererPort -or $null -ne $Snapshot.MainPort){
        Throw-CcodStaticProbeError 'CCOD_STATIC_TARGET_CHANGED' 'The ordinary target identity changed' $null
    }
    return $Snapshot
}

function Test-CcodStaticPackageMatch {
    param($Left,$Right)
    if($null -eq $Left -or $null -eq $Right){return $false}
    return $Left.FullName -is [string] -and $Right.FullName -is [string] -and $Left.FullName -ceq $Right.FullName -and
        $Left.FamilyName -ceq $Right.FamilyName -and $Left.Version -ceq $Right.Version -and $Left.ExecutablePath.Equals($Right.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)
}

function Assert-CcodStaticSettings {
    param($Settings)
    Assert-CcodStaticExactObject $Settings @('schemaVersion','automationEnabled','candidateCompatibleOptIn','nodeCandidates','updatedAtUtc') 'CCOD_STATIC_STATE_INVALID' 'Settings'|Out-Null
    if($Settings.schemaVersion -isnot [int] -or $Settings.schemaVersion -ne 1 -or $Settings.automationEnabled -isnot [bool] -or $Settings.candidateCompatibleOptIn -isnot [bool] -or
        $Settings.nodeCandidates -is [string] -or $Settings.nodeCandidates -isnot [Collections.IEnumerable] -or -not(Test-CcodStaticCanonicalUtc $Settings.updatedAtUtc)){Throw-CcodStaticProbeError 'CCOD_STATIC_STATE_INVALID' 'Settings are invalid' $null}
    foreach($candidate in @($Settings.nodeCandidates)){
        $full=$null;try{$full=[IO.Path]::GetFullPath($candidate)}catch{}
        if($candidate -isnot [string] -or $null -eq $full -or -not[IO.Path]::IsPathRooted($candidate) -or $full -cne $candidate -or [IO.Path]::GetFileName($candidate) -cne 'node.exe'){Throw-CcodStaticProbeError 'CCOD_STATIC_STATE_INVALID' 'Settings contain an unauthorized Node candidate' $null}
    }
    return $Settings
}

function ConvertTo-CcodStaticProcessArgument {
    param([string]$Argument)
    $quoted=[Text.StringBuilder]::new();[void]$quoted.Append('"');$slashes=0
    foreach($character in $Argument.ToCharArray()){
        if($character -eq [char]'\'){$slashes++;continue}
        if($character -eq [char]'"'){[void]$quoted.Append(('\'*(($slashes*2)+1)));[void]$quoted.Append('"');$slashes=0;continue}
        if($slashes -gt 0){[void]$quoted.Append(('\'*$slashes));$slashes=0};[void]$quoted.Append($character)
    }
    if($slashes -gt 0){[void]$quoted.Append(('\'*($slashes*2)))};[void]$quoted.Append('"');return $quoted.ToString()
}

function Test-CcodStaticOwnedNodeIdentityMatch {
    param($Identity,$Owned)
    return $null -ne $Identity -and $null -ne $Owned -and $Identity.Pid -is [int] -and $Owned.Pid -is [int] -and
        $Identity.Pid -eq $Owned.Pid -and $Identity.CreationTimeUtc -is [string] -and $Owned.CreationTimeUtc -is [string] -and
        $Identity.CreationTimeUtc -ceq $Owned.CreationTimeUtc
}

function Assert-CcodStaticNodeTerminationReceipt {
    param($Receipt,$Owned)
    Assert-CcodStaticExactObject $Receipt @('Pid','CreationTimeUtc','Exited') 'CCOD_STATIC_PROBE_FAILED' 'Node termination receipt'|Out-Null
    if($Receipt.Pid -isnot [int] -or $Receipt.Pid -ne $Owned.Pid -or $Receipt.CreationTimeUtc -isnot [string] -or
        $Receipt.CreationTimeUtc -cne $Owned.CreationTimeUtc -or $Receipt.Exited -isnot [bool] -or -not $Receipt.Exited){
        Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The owned Node helper exit was not confirmed' $null
    }
    return $Receipt
}

function New-CcodStaticOwnedNodeCleanupReceipt {
    param($Owned)
    return [pscustomobject][ordered]@{Pid=$Owned.Pid;CreationTimeUtc=$Owned.CreationTimeUtc;Handle=$Owned.Handle}
}

function Invoke-CcodStaticOwnedNodeCleanupAttempt {
    param($Owned,[hashtable]$Adapter)
    $current=Invoke-CcodStaticAdapter $Adapter.GetProcessIdentity @($Owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
    if($null -ne $current -and -not(Test-CcodStaticOwnedNodeIdentityMatch $current $Owned)){return $true}
    $termination=Invoke-CcodStaticAdapter $Adapter.TerminateNode @($Owned) Single 'CCOD_STATIC_PROBE_FAILED'
    Assert-CcodStaticNodeTerminationReceipt $termination $Owned|Out-Null
    $after=Invoke-CcodStaticAdapter $Adapter.GetProcessIdentity @($Owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
    if(Test-CcodStaticOwnedNodeIdentityMatch $after $Owned){throw 'owned helper remains alive'}
    return $true
}

function Invoke-CcodStaticOwnedNodeCleanup {
    param($Owned,[hashtable]$Adapter)
    $privateReceipt=New-CcodStaticOwnedNodeCleanupReceipt $Owned
    for($attempt=0;$attempt -lt 2;$attempt++){
        try{return Invoke-CcodStaticOwnedNodeCleanupAttempt $Owned $Adapter}catch{}
    }
    Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The owned Node helper cleanup could not be confirmed' $privateReceipt
}

function Get-CcodStaticNodeStartAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        CreateProcess={param($StartInfo)$value=[Diagnostics.Process]::new();$value.StartInfo=$StartInfo;return $value}
        StartProcess={param($Process)$Process.Start()}
        GetStartedIdentity={param($Process)[pscustomobject][ordered]@{Pid=[int]$Process.Id;CreationTimeUtc=$Process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}}
        BeginRead={param($Process)[pscustomobject][ordered]@{StdoutTask=$Process.StandardOutput.ReadToEndAsync();StderrTask=$Process.StandardError.ReadToEndAsync()}}
        GetProcessIdentity={param($ProcessId)Get-CcodStaticGenericProcessIdentity $ProcessId}
        TerminateStarted={param($Process,$Owned)$Process.Kill();$exited=$Process.WaitForExit(5000);[pscustomobject][ordered]@{Pid=$Owned.Pid;CreationTimeUtc=$Owned.CreationTimeUtc;Exited=[bool]$exited}}
        TerminateUnbound={param($Process)if($Process.HasExited){return $true};$Process.Kill();return [bool]$Process.WaitForExit(5000)}
        DisposeProcess={param($Process)if($Process -is [IDisposable]){$Process.Dispose()}}
    }
    if($null -ne $Adapters){foreach($key in $Adapters.Keys){$resolved[$key]=$Adapters[$key]}}
    return $resolved
}

function Test-CcodStaticPrivateNodeCleanupReceipt {
    param($Receipt)
    if($null -eq $Receipt -or $Receipt -isnot [pscustomobject]){return $false}
    $properties=@($Receipt.PSObject.Properties)
    if($properties.Count -ne 3 -or $properties[0].Name -cne 'Pid' -or $properties[1].Name -cne 'CreationTimeUtc' -or $properties[2].Name -cne 'Handle'){return $false}
    return $null -ne $Receipt.Handle -and (($Receipt.Pid -is [int] -and $Receipt.Pid -gt 0 -and (Test-CcodStaticCanonicalUtc $Receipt.CreationTimeUtc)) -or ($null -eq $Receipt.Pid -and $null -eq $Receipt.CreationTimeUtc))
}

function Invoke-CcodStaticPartialNodeCleanup {
    param($Receipt,[hashtable]$Adapters)
    if(-not(Test-CcodStaticPrivateNodeCleanupReceipt $Receipt)){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The private Node cleanup receipt is invalid' $null}
    $adapter=Get-CcodStaticNodeStartAdapters $Adapters;$cleanupConfirmed=$false
    if($Receipt.Pid -is [int]){
        $owned=[pscustomobject][ordered]@{Pid=$Receipt.Pid;CreationTimeUtc=$Receipt.CreationTimeUtc;Handle=$Receipt.Handle;StdoutTask=$null;StderrTask=$null}
        try{
            $current=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
            if($null -ne $current -and -not(Test-CcodStaticOwnedNodeIdentityMatch $current $owned)){$cleanupConfirmed=$true}
            elseif($null -ne $current){
                $termination=Invoke-CcodStaticAdapter $adapter.TerminateStarted @($Receipt.Handle,$owned) Single 'CCOD_STATIC_PROBE_FAILED'
                Assert-CcodStaticNodeTerminationReceipt $termination $owned|Out-Null
                $after=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
                if(Test-CcodStaticOwnedNodeIdentityMatch $after $owned){throw 'recovered helper remains alive'}
                $cleanupConfirmed=$true
            }
        }catch{}
    }
    if(-not $cleanupConfirmed){
        try{
            $unbound=Invoke-CcodStaticAdapter $adapter.TerminateUnbound @($Receipt.Handle) Single 'CCOD_STATIC_PROBE_FAILED'
            if($unbound -isnot [bool] -or -not $unbound){throw 'recovered exact handle remains alive'}
            if($Receipt.Pid -is [int]){
                $after=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($Receipt.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
                $receiptIdentity=[pscustomobject][ordered]@{Pid=$Receipt.Pid;CreationTimeUtc=$Receipt.CreationTimeUtc}
                if(Test-CcodStaticOwnedNodeIdentityMatch $after $receiptIdentity){throw 'recovered exact identity remains alive'}
            }
            $cleanupConfirmed=$true
        }catch{}
    }
    if(-not $cleanupConfirmed){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The private Node cleanup receipt remains owned' $Receipt}
    try{Invoke-CcodStaticAdapter $adapter.DisposeProcess @($Receipt.Handle) None 'CCOD_STATIC_PROBE_FAILED'|Out-Null}catch{Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The recovered Node helper handle could not be released' $Receipt}
    return $true
}

function Start-CcodStaticOwnedNode {
    param([string]$Path,[string[]]$Arguments,[hashtable]$Adapters)
    $adapter=Get-CcodStaticNodeStartAdapters $Adapters
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Path;$info.Arguments=(($Arguments|ForEach-Object{ConvertTo-CcodStaticProcessArgument $_}) -join ' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=$null;$startAttempted=$false;$started=$false;$owned=$null
    try{
        $process=Invoke-CcodStaticAdapter $adapter.CreateProcess @($info) Single 'CCOD_STATIC_PROBE_FAILED'
        if($null -eq $process){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The Node process handle is unavailable' $null}
        $startAttempted=$true;$startResult=Invoke-CcodStaticAdapter $adapter.StartProcess @($process) Single 'CCOD_STATIC_PROBE_FAILED'
        if($startResult -isnot [bool] -or -not $startResult){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The Node helper could not be started' $null}
        $started=$true
        $identity=Invoke-CcodStaticAdapter $adapter.GetStartedIdentity @($process) Single 'CCOD_STATIC_PROBE_FAILED'
        Assert-CcodStaticExactObject $identity @('Pid','CreationTimeUtc') 'CCOD_STATIC_PROBE_FAILED' 'Started Node identity'|Out-Null
        if($identity.Pid -isnot [int] -or $identity.Pid -lt 1 -or -not(Test-CcodStaticCanonicalUtc $identity.CreationTimeUtc)){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The started Node identity is invalid' $null}
        $owned=[pscustomobject][ordered]@{Pid=$identity.Pid;CreationTimeUtc=$identity.CreationTimeUtc;Handle=$process;StdoutTask=$null;StderrTask=$null}
        $reads=Invoke-CcodStaticAdapter $adapter.BeginRead @($process) Single 'CCOD_STATIC_PROBE_FAILED'
        Assert-CcodStaticExactObject $reads @('StdoutTask','StderrTask') 'CCOD_STATIC_PROBE_FAILED' 'Node output readers'|Out-Null
        $owned.StdoutTask=$reads.StdoutTask;$owned.StderrTask=$reads.StderrTask
        return $owned
    }catch{
        $cleanupConfirmed=$false
        if($startAttempted -and $started -and $null -eq $owned){
            try{
                $retry=Invoke-CcodStaticAdapter $adapter.GetStartedIdentity @($process) Single 'CCOD_STATIC_PROBE_FAILED'
                Assert-CcodStaticExactObject $retry @('Pid','CreationTimeUtc') 'CCOD_STATIC_PROBE_FAILED' 'Started Node identity'|Out-Null
                if($retry.Pid -isnot [int] -or $retry.Pid -lt 1 -or -not(Test-CcodStaticCanonicalUtc $retry.CreationTimeUtc)){throw 'identity retry'}
                $owned=[pscustomobject][ordered]@{Pid=$retry.Pid;CreationTimeUtc=$retry.CreationTimeUtc;Handle=$process;StdoutTask=$null;StderrTask=$null}
            }catch{}
        }
        if($startAttempted -and $started -and $null -ne $owned){
            try{
                $current=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
                if($null -ne $current -and -not(Test-CcodStaticOwnedNodeIdentityMatch $current $owned)){$cleanupConfirmed=$true}
                elseif($null -ne $current){
                    $termination=Invoke-CcodStaticAdapter $adapter.TerminateStarted @($process,$owned) Single 'CCOD_STATIC_PROBE_FAILED'
                    Assert-CcodStaticNodeTerminationReceipt $termination $owned|Out-Null
                    $after=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
                    if(Test-CcodStaticOwnedNodeIdentityMatch $after $owned){throw 'started helper remains alive'}
                    $cleanupConfirmed=$true
                }
            }catch{}
        }
        if($startAttempted -and -not $cleanupConfirmed){
            try{
                $unbound=Invoke-CcodStaticAdapter $adapter.TerminateUnbound @($process) Single 'CCOD_STATIC_PROBE_FAILED'
                if($unbound -isnot [bool] -or -not $unbound){throw 'exact process handle remains alive'}
                if($null -ne $owned){
                    $after=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($owned.Pid) OptionalSingle 'CCOD_STATIC_PROBE_FAILED'
                    if(Test-CcodStaticOwnedNodeIdentityMatch $after $owned){throw 'exact process identity remains alive'}
                }
                $cleanupConfirmed=$true
            }catch{}
        }
        if($cleanupConfirmed -and $null -ne $process){
            try{Invoke-CcodStaticAdapter $adapter.DisposeProcess @($process) None 'CCOD_STATIC_PROBE_FAILED'|Out-Null}catch{Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The stopped Node helper handle could not be released' $null}
            Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The Node helper failed during bounded startup' $null
        }
        $privateReceipt=[pscustomobject][ordered]@{Pid=$(if($null -eq $owned){$null}else{$owned.Pid});CreationTimeUtc=$(if($null -eq $owned){$null}else{$owned.CreationTimeUtc});Handle=$process}
        Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The Node helper cleanup could not be confirmed' $privateReceipt
    }
}

function Get-CcodStaticOwnedNodeAdapters {
    param([hashtable]$Adapters)
    $nodeStartAdapters=if($null -ne $Adapters -and $Adapters.ContainsKey('NodeStartAdapters')){$Adapters.NodeStartAdapters}else{$null}
    $resolved=@{
        StartNode={param($Path,$Arguments)Start-CcodStaticOwnedNode $Path $Arguments $nodeStartAdapters}.GetNewClosure()
        RecoverStartNode={param($Receipt)Invoke-CcodStaticPartialNodeCleanup $Receipt $nodeStartAdapters}.GetNewClosure()
        WaitNode={param($Owned,$Milliseconds)$Owned.Handle.WaitForExit([int]$Milliseconds)}
        GetProcessIdentity={param($ProcessId)Get-CcodStaticGenericProcessIdentity $ProcessId}
        TerminateNode={param($Owned)if(-not $Owned.Handle.HasExited){$Owned.Handle.Kill()};$exited=$Owned.Handle.HasExited -or $Owned.Handle.WaitForExit(5000);[pscustomobject][ordered]@{Pid=$Owned.Pid;CreationTimeUtc=$Owned.CreationTimeUtc;Exited=[bool]$exited}}
        FinishNode={
            param($Owned,$Milliseconds)
            if($Milliseconds -isnot [int] -or $Milliseconds -lt 1){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
            $finishWatch=[Diagnostics.Stopwatch]::StartNew()
            if(-not $Owned.Handle.WaitForExit($Milliseconds)){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
            $remaining=[int]([long]$Milliseconds-[long]$finishWatch.ElapsedMilliseconds)
            if($remaining -lt 1){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
            $tasks=[Threading.Tasks.Task[]]@($Owned.StdoutTask,$Owned.StderrTask)
            if($tasks.Count -ne 2 -or $null -eq $tasks[0] -or $null -eq $tasks[1] -or -not [Threading.Tasks.Task]::WaitAll($tasks,$remaining)){
                Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null
            }
            [pscustomobject][ordered]@{ExitCode=[int]$Owned.Handle.ExitCode;Stdout=[string]$Owned.StdoutTask.GetAwaiter().GetResult();Stderr=[string]$Owned.StderrTask.GetAwaiter().GetResult()}
        }
        DisposeNode={param($Owned)if($null -ne $Owned.Handle -and $Owned.Handle -is [IDisposable]){$Owned.Handle.Dispose()}}
    }
    if($null -ne $Adapters){foreach($key in $Adapters.Keys){if($key -cne 'NodeStartAdapters'){$resolved[$key]=$Adapters[$key]}}}
    return $resolved
}

function Invoke-CcodStaticFinalNodeCleanup {
    param($Receipt,[hashtable]$OwnedAdapters)
    if(-not(Test-CcodStaticPrivateNodeCleanupReceipt $Receipt)){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The final private Node cleanup receipt is invalid' $null}
    if(($null -ne $OwnedAdapters -and $OwnedAdapters.ContainsKey('NodeStartAdapters')) -or $null -eq $Receipt.Pid){
        $startAdapters=if($null -ne $OwnedAdapters -and $OwnedAdapters.ContainsKey('NodeStartAdapters')){$OwnedAdapters.NodeStartAdapters}else{$null}
        try{Invoke-CcodStaticPartialNodeCleanup $Receipt $startAdapters|Out-Null;return $true}catch{Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The final partial Node cleanup could not be confirmed' $Receipt}
    }
    $adapter=Get-CcodStaticOwnedNodeAdapters $OwnedAdapters
    $owned=[pscustomobject][ordered]@{Pid=$Receipt.Pid;CreationTimeUtc=$Receipt.CreationTimeUtc;Handle=$Receipt.Handle;StdoutTask=$null;StderrTask=$null}
    try{
        Invoke-CcodStaticOwnedNodeCleanupAttempt $owned $adapter|Out-Null
        Invoke-CcodStaticAdapter $adapter.DisposeNode @($owned) None 'CCOD_STATIC_PROBE_FAILED'|Out-Null
        return $true
    }catch{Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The final owned Node cleanup could not be confirmed' $Receipt}
}

function Invoke-CcodStaticProbeOwnedNode {
    [CmdletBinding()]
    param([string]$NodePath,[string[]]$Arguments,[int]$TimeoutMilliseconds,[hashtable]$Adapters)
    if($TimeoutMilliseconds -lt 1){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
    $adapter=Get-CcodStaticOwnedNodeAdapters $Adapters;$owned=$null;$safeToDispose=$false;$helperExited=$false;$preserveTimeout=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $owned=Invoke-CcodStaticAdapter $adapter.StartNode @($NodePath,$Arguments) Single 'CCOD_STATIC_PROBE_FAILED'
        if($null -eq $owned -or $owned.Pid -isnot [int] -or $owned.Pid -lt 1 -or -not(Test-CcodStaticCanonicalUtc $owned.CreationTimeUtc)){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The owned Node helper identity is invalid' $null}
        $remaining=[int]([long]$TimeoutMilliseconds-[long]$watch.ElapsedMilliseconds)
        if($remaining -lt 1){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
        $waited=Invoke-CcodStaticAdapter $adapter.WaitNode @($owned,$remaining) Single 'CCOD_STATIC_PROBE_FAILED'
        if($waited -isnot [bool]){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The owned Node wait result is invalid' $null}
        if(-not $waited){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
        $helperExited=$true;$safeToDispose=$true
        $remaining=[int]([long]$TimeoutMilliseconds-[long]$watch.ElapsedMilliseconds)
        if($remaining -lt 1){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
        $value=Invoke-CcodStaticAdapter $adapter.FinishNode @($owned,$remaining) Single 'CCOD_STATIC_PROBE_FAILED'
        if($watch.ElapsedMilliseconds -ge $TimeoutMilliseconds){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
        return $value
    }catch{
        $failure=$_;$failureId=Get-CcodStaticProbeErrorId $failure;$ownershipResolved=$helperExited
        if($null -ne $owned -and -not $helperExited){
            Invoke-CcodStaticOwnedNodeCleanup $owned $adapter|Out-Null
            $safeToDispose=$true;$ownershipResolved=$true
        }elseif($null -eq $owned -and (Test-CcodStaticPrivateNodeCleanupReceipt $failure.TargetObject)){
            $recovered=Invoke-CcodStaticAdapter $adapter.RecoverStartNode @($failure.TargetObject) Single 'CCOD_STATIC_PROBE_FAILED'
            if($recovered -isnot [bool] -or -not $recovered){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The partial Node helper cleanup was not recovered' $failure.TargetObject}
            $ownershipResolved=$true
        }
        if($failureId -ceq 'CCOD_STATIC_PROBE_TIMEOUT' -or $watch.ElapsedMilliseconds -ge $TimeoutMilliseconds){
            $preserveTimeout=$true
            Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null
        }
        if($ownershipResolved){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The owned Node helper failed after exact cleanup' $null}
        throw $failure
    }finally{
        if($null -ne $owned -and $safeToDispose){
            try{Invoke-CcodStaticAdapter $adapter.DisposeNode @($owned) None 'CCOD_STATIC_PROBE_FAILED'|Out-Null}catch{if(-not $preserveTimeout){throw}}
        }
    }
}

function New-CcodStaticDeadline {
    param([int]$TimeoutMilliseconds)
    return [pscustomobject][ordered]@{TimeoutMilliseconds=$TimeoutMilliseconds;Stopwatch=[Diagnostics.Stopwatch]::StartNew();TimedOut=$false}
}

function Get-CcodStaticRemainingMilliseconds {
    param($Deadline)
    $remaining=[long]$Deadline.TimeoutMilliseconds-[long]$Deadline.Stopwatch.ElapsedMilliseconds
    if($remaining -le 0){return 0};if($remaining -gt [int]::MaxValue){return [int]::MaxValue};return [int]$remaining
}

function Invoke-CcodStaticProbeWithDeadline {
    param([string[]]$NodeCandidates,[string]$CheckerPath,$Deadline,[hashtable]$WorkerAdapters,$InvokeStaticProbe)
    if($null -eq $Deadline -or $Deadline.TimedOut -isnot [bool] -or $InvokeStaticProbe -isnot [scriptblock]){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The bounded static probe contract is invalid' $null}
    $ownedAdapters=if($null -ne $WorkerAdapters -and $WorkerAdapters.ContainsKey('OwnedNodeAdapters')){$WorkerAdapters.OwnedNodeAdapters}else{$null};$cleanupLatch=[pscustomobject]@{Receipt=$null}
    $getRemainingCallback=(Get-Command Get-CcodStaticRemainingMilliseconds -CommandType Function -ErrorAction Stop).ScriptBlock
    $invokeOwnedCallback=(Get-Command Invoke-CcodStaticProbeOwnedNode -CommandType Function -ErrorAction Stop).ScriptBlock
    $getErrorIdCallback=(Get-Command Get-CcodStaticProbeErrorId -CommandType Function -ErrorAction Stop).ScriptBlock
    $throwErrorCallback=(Get-Command Throw-CcodStaticProbeError -CommandType Function -ErrorAction Stop).ScriptBlock
    $testCleanupReceiptCallback=(Get-Command Test-CcodStaticPrivateNodeCleanupReceipt -CommandType Function -ErrorAction Stop).ScriptBlock
    $finalCleanupCallback=(Get-Command Invoke-CcodStaticFinalNodeCleanup -CommandType Function -ErrorAction Stop).ScriptBlock
    $nodeAdapters=@{
        GetNodeVersion={param($NodePath)try{if($null -ne $cleanupLatch.Receipt){& $throwErrorCallback 'CCOD_STATIC_PROBE_FAILED' 'A private Node cleanup remains pending' $cleanupLatch.Receipt};$remaining=& $getRemainingCallback $Deadline;$value=& $invokeOwnedCallback $NodePath @('--version') $remaining $ownedAdapters;if($value.ExitCode -ne 0){throw 'node version failed'};return ([string]$value.Stdout).Trim()}catch{$caught=$_;if((& $getErrorIdCallback $caught) -ceq 'CCOD_STATIC_PROBE_TIMEOUT'){$Deadline.TimedOut=$true};if($null -eq $cleanupLatch.Receipt -and (& $testCleanupReceiptCallback $caught.TargetObject)){$cleanupLatch.Receipt=[pscustomobject][ordered]@{Pid=$caught.TargetObject.Pid;CreationTimeUtc=$caught.TargetObject.CreationTimeUtc;Handle=$caught.TargetObject.Handle}};throw $caught}}.GetNewClosure()
        InvokeNode={param($NodePath,$Arguments)try{if($null -ne $cleanupLatch.Receipt){& $throwErrorCallback 'CCOD_STATIC_PROBE_FAILED' 'A private Node cleanup remains pending' $cleanupLatch.Receipt};$remaining=& $getRemainingCallback $Deadline;return & $invokeOwnedCallback $NodePath @($Arguments) $remaining $ownedAdapters}catch{$caught=$_;if((& $getErrorIdCallback $caught) -ceq 'CCOD_STATIC_PROBE_TIMEOUT'){$Deadline.TimedOut=$true};if($null -eq $cleanupLatch.Receipt -and (& $testCleanupReceiptCallback $caught.TargetObject)){$cleanupLatch.Receipt=[pscustomobject][ordered]@{Pid=$caught.TargetObject.Pid;CreationTimeUtc=$caught.TargetObject.CreationTimeUtc;Handle=$caught.TargetObject.Handle}};throw $caught}}.GetNewClosure()
    }
    $probe=$null;$failure=$null
    try{$probe=Invoke-CcodStaticAdapter $InvokeStaticProbe @(@($NodeCandidates),$CheckerPath,$nodeAdapters) Single 'CCOD_STATIC_PROBE_FAILED'}catch{$failure=$_}
    if($null -ne $cleanupLatch.Receipt){
        $cleaned=& $finalCleanupCallback $cleanupLatch.Receipt $ownedAdapters
        if($cleaned -isnot [bool] -or -not $cleaned){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The final private Node cleanup was not confirmed' $cleanupLatch.Receipt}
        Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'The static probe encountered a private Node cleanup failure' $null
    }
    if($Deadline.TimedOut){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_TIMEOUT' 'The static probe deadline expired' $null}
    if($null -ne $failure){throw $failure}
    return $probe
}

function ConvertTo-CcodStaticProbePublicResult {
    param($Task4Probe,$Request)
    if($null -eq $Task4Probe -or $Task4Probe.Code -isnot [string] -or $Task4Probe.Code -cne 'CHECKER_OK'){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'Task 4 did not produce a valid classification' $null}
    $result=[pscustomobject][ordered]@{
        schemaVersion=1;action='StaticProbe';ok=$true;requestId=$Request.requestId;runtimeId=$Request.runtimeId;targetIdentity=Copy-CcodStaticTargetIdentity $Request.targetIdentity
        probe=[pscustomobject][ordered]@{
            ready=$Task4Probe.Ready;code=$Task4Probe.Code;staticClassification=$Task4Probe.StaticClassification;affectedBuildDetected=$Task4Probe.AffectedBuildDetected;packageInstalled=$Task4Probe.PackageInstalled
            packageFullName=$Task4Probe.PackageFullName;packageFamilyName=$Task4Probe.PackageFamilyName;packageVersion=$Task4Probe.PackageVersion;executablePath=$Task4Probe.ExecutablePath
            appAsarSha256=$Task4Probe.AppAsarSha256;nodeVersion=$Task4Probe.NodeVersion;nodeMajor=$Task4Probe.NodeMajor;nodeSupported=$Task4Probe.NodeSupported;nativeModulePresent=$Task4Probe.NativeModulePresent
            signatures=[pscustomobject][ordered]@{invertedGate=$Task4Probe.Signatures.invertedGate;deviceKeyModuleReference=$Task4Probe.Signatures.deviceKeyModuleReference;macOnlyGuard=$Task4Probe.Signatures.macOnlyGuard;windowsControllerUi=$Task4Probe.Signatures.windowsControllerUi}
        };error=$null
    }
    Assert-CcodStaticProbeResult $result $Request|Out-Null
    return $result
}

function Get-CcodStaticProbeWorkerAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        GetScriptPath={$script:CcodStaticProbeWorkerScriptPath}
        AuthorizeRuntime={param($Path)Get-CcodStaticProbeRuntimeAuthorization $Path}
        ImportRuntime={param($Context)Import-CcodStaticProbeRuntime $Context}
        CompleteRuntimeAuthorization={param($Context,$RuntimeApi)Complete-CcodStaticProbeRuntimeAuthorization $Context $RuntimeApi}
        ReauthorizeRuntime={param($Path)$value=Get-CcodStaticProbeRuntimeAuthorization $Path;$api=Import-CcodStaticProbeRuntime $value;Complete-CcodStaticProbeRuntimeAuthorization $value $api}
        ReadRequest={param($Path,$RuntimeApi)& $RuntimeApi.ReadStrictJson -Path $Path -ExpectedSchema 1 -Kind 'static probe request'}
        ReadSettings={param($StateRoot,$RuntimeApi)& $RuntimeApi.ReadSettings -StateRoot $StateRoot}
        GetCurrentIdentity={Get-CcodStaticCurrentIdentity}
        GetParentProcessId={Get-CcodStaticParentProcessId}
        GetProcessIdentity={param($ProcessId)Get-CcodStaticGenericProcessIdentity $ProcessId}
        GetPackageIdentity={param($RuntimeApi)& $RuntimeApi.GetPackageIdentity}
        GetTargetSnapshot={param($ProcessId,$Package,$RuntimeApi)$bound=$Package;& $RuntimeApi.GetProcessSnapshot -ProcessId $ProcessId -Adapters @{GetPackageIdentity={$bound}.GetNewClosure()}}
        StartDeadline={param($Timeout)New-CcodStaticDeadline $Timeout}
        InvokeProbe=$null
        WriteResult={param($Path,$Value,$RuntimeApi)Write-CcodStaticProbeLocalAtomicJson -Path $Path -Value $Value}
        WriteStdout={param($Line)[Console]::Out.WriteLine($Line)}
        WriteStderr={param($Line)[Console]::Error.WriteLine($Line)}
    }
    if($null -ne $Adapters){foreach($key in $Adapters.Keys){$resolved[$key]=$Adapters[$key]}}
    if($null -eq $resolved.InvokeProbe){$allAdapters=$resolved;$resolved.InvokeProbe={param($NodeCandidates,$CheckerPath,$Deadline,$RuntimeApi)Invoke-CcodStaticProbeWithDeadline $NodeCandidates $CheckerPath $Deadline $allAdapters $RuntimeApi.InvokeStaticProbe}.GetNewClosure()}
    return $resolved
}

function Get-CcodStaticFailureForStage {
    param([string]$Stage,$Failure)
    $id=Get-CcodStaticProbeErrorId $Failure
    if($script:CcodStaticProbeErrorCodes -ccontains $id){return $id}
    switch($Stage){
        'InputValidation'{return 'CCOD_STATIC_REQUEST_INVALID'}'RuntimeAuthorization'{return 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'}'ModuleLoad'{return 'CCOD_STATIC_MODULE_LOAD_FAILED'}
        'StateRead'{return 'CCOD_STATIC_STATE_INVALID'}'SupervisorPreflight'{return 'CCOD_STATIC_SUPERVISOR_CHANGED'}'SupervisorPostflight'{return 'CCOD_STATIC_SUPERVISOR_CHANGED'}
        'TargetPreflight'{return 'CCOD_STATIC_TARGET_CHANGED'}'TargetPostflight'{return 'CCOD_STATIC_TARGET_CHANGED'}'RuntimePostflight'{return 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'}
        'ResultValidation'{return 'CCOD_STATIC_RESULT_INVALID'}default{return 'CCOD_STATIC_PROBE_FAILED'}
    }
}

function Invoke-CcodStaticProbeWorker {
    [CmdletBinding()]
    param([string]$RequestPath,[string]$ResultPath,[hashtable]$Adapters)
    $adapter=Get-CcodStaticProbeWorkerAdapters $Adapters;$request=$null;$requestValid=$false;$context=$null;$runtimeApi=$null;$canPublish=$false;$result=$null;$stage='RuntimeAuthorization'
    try{
        $scriptPath=Invoke-CcodStaticAdapter $adapter.GetScriptPath @() Single 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        $context=Invoke-CcodStaticAdapter $adapter.AuthorizeRuntime @($scriptPath) Single 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        $stage='InputValidation';Assert-CcodStaticProbeFramingPaths $context $RequestPath $ResultPath $null -Adapters $Adapters;$canPublish=$true
        $request=Read-CcodStaticProbeLocalJson $RequestPath 'CCOD_STATIC_REQUEST_INVALID';Assert-CcodStaticProbeRequest $request|Out-Null;$requestValid=$true
        $stage='RuntimeAuthorization';if($request.runtimeId -cne $context.RuntimeId){Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'The request runtime is not the active authorized runtime' $null}
        $stage='InputValidation';$canPublish=$false;Assert-CcodStaticProbeFramingPaths $context $RequestPath $ResultPath $request -RequireCorrelation -Adapters $Adapters;$canPublish=$true
        $stage='ModuleLoad';$runtimeApi=Invoke-CcodStaticAdapter $adapter.ImportRuntime @($context) Single 'CCOD_STATIC_MODULE_LOAD_FAILED'
        $stage='RuntimeAuthorization';$context=Invoke-CcodStaticAdapter $adapter.CompleteRuntimeAuthorization @($context,$runtimeApi) Single 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        $stage='InputValidation';$verifiedRequest=Invoke-CcodStaticAdapter $adapter.ReadRequest @($RequestPath,$runtimeApi) Single 'CCOD_STATIC_REQUEST_INVALID';Assert-CcodStaticProbeRequest $verifiedRequest|Out-Null
        if(-not(Test-CcodStaticProbeRequestMatch $request $verifiedRequest)){Throw-CcodStaticProbeError 'CCOD_STATIC_REQUEST_INVALID' 'The static probe request changed during authorization' $null};$request=$verifiedRequest
        $stage='StaticProbe';$deadline=Invoke-CcodStaticAdapter $adapter.StartDeadline @($request.timeoutMilliseconds) Single 'CCOD_STATIC_PROBE_FAILED'
        $stage='StateRead';$settings=Invoke-CcodStaticAdapter $adapter.ReadSettings @($context.StateRoot,$runtimeApi) Single 'CCOD_STATIC_STATE_INVALID';Assert-CcodStaticSettings $settings|Out-Null
        $stage='SupervisorPreflight';$current=Invoke-CcodStaticAdapter $adapter.GetCurrentIdentity @() Single 'CCOD_STATIC_SUPERVISOR_CHANGED';Assert-CcodStaticCurrentIdentity $current $request|Out-Null
        $parentPid=Invoke-CcodStaticAdapter $adapter.GetParentProcessId @() Single 'CCOD_STATIC_SUPERVISOR_CHANGED';if($parentPid -isnot [int]){Throw-CcodStaticProbeError 'CCOD_STATIC_SUPERVISOR_CHANGED' 'The supervisor parent is unavailable' $null}
        $parentBefore=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($request.supervisorIdentity.pid) Single 'CCOD_STATIC_SUPERVISOR_CHANGED';Assert-CcodStaticSupervisorIdentity $parentBefore $parentPid $request $current|Out-Null
        $stage='TargetPreflight';$packageBefore=Invoke-CcodStaticAdapter $adapter.GetPackageIdentity @($runtimeApi) Single 'CCOD_STATIC_PACKAGE_CHANGED';Assert-CcodStaticPackageIdentity $packageBefore|Out-Null
        $targetBefore=Invoke-CcodStaticAdapter $adapter.GetTargetSnapshot @($request.targetIdentity.pid,$packageBefore,$runtimeApi) Single 'CCOD_STATIC_TARGET_CHANGED';Assert-CcodStaticTargetSnapshot $targetBefore $request $current $packageBefore|Out-Null
        $stage='StaticProbe';$task4=Invoke-CcodStaticAdapter $adapter.InvokeProbe @(@($settings.nodeCandidates),$context.CheckerPath,$deadline,$runtimeApi) Single 'CCOD_STATIC_PROBE_FAILED'
        if($null -eq $task4 -or $task4.Code -isnot [string] -or $task4.Code -cne 'CHECKER_OK'){Throw-CcodStaticProbeError 'CCOD_STATIC_PROBE_FAILED' 'Task 4 static probe failed' $null}
        $probePackage=[pscustomobject][ordered]@{FullName=$task4.PackageFullName;FamilyName=$task4.PackageFamilyName;Version=$task4.PackageVersion;ExecutablePath=$task4.ExecutablePath}
        Assert-CcodStaticPackageIdentity ([pscustomobject][ordered]@{Found=$true;FullName=$probePackage.FullName;FamilyName=$probePackage.FamilyName;Version=$probePackage.Version;ExecutablePath=$probePackage.ExecutablePath})|Out-Null
        if(-not(Test-CcodStaticPackageMatch $packageBefore $probePackage)){Throw-CcodStaticProbeError 'CCOD_STATIC_PACKAGE_CHANGED' 'The package changed during static inspection' $null}
        $stage='SupervisorPostflight';$currentAfter=Invoke-CcodStaticAdapter $adapter.GetCurrentIdentity @() Single 'CCOD_STATIC_SUPERVISOR_CHANGED';Assert-CcodStaticCurrentIdentity $currentAfter $request|Out-Null
        $parentPidAfter=Invoke-CcodStaticAdapter $adapter.GetParentProcessId @() Single 'CCOD_STATIC_SUPERVISOR_CHANGED';if($parentPidAfter -isnot [int]){Throw-CcodStaticProbeError 'CCOD_STATIC_SUPERVISOR_CHANGED' 'The supervisor parent is unavailable' $null}
        $parentAfter=Invoke-CcodStaticAdapter $adapter.GetProcessIdentity @($request.supervisorIdentity.pid) Single 'CCOD_STATIC_SUPERVISOR_CHANGED';Assert-CcodStaticSupervisorIdentity $parentAfter $parentPidAfter $request $currentAfter|Out-Null
        if($currentAfter.Pid -ne $current.Pid -or $currentAfter.UserSid -cne $current.UserSid -or $currentAfter.SessionId -ne $current.SessionId -or $parentAfter.CreationTimeUtc -cne $parentBefore.CreationTimeUtc){Throw-CcodStaticProbeError 'CCOD_STATIC_SUPERVISOR_CHANGED' 'The supervisor identity changed after probing' $null}
        $stage='TargetPostflight';$packageAfter=Invoke-CcodStaticAdapter $adapter.GetPackageIdentity @($runtimeApi) Single 'CCOD_STATIC_PACKAGE_CHANGED';Assert-CcodStaticPackageIdentity $packageAfter|Out-Null
        $targetAfter=Invoke-CcodStaticAdapter $adapter.GetTargetSnapshot @($request.targetIdentity.pid,$packageAfter,$runtimeApi) Single 'CCOD_STATIC_TARGET_CHANGED';Assert-CcodStaticTargetSnapshot $targetAfter $request $currentAfter $packageAfter|Out-Null
        if(-not(Test-CcodStaticPackageMatch $packageBefore $packageAfter) -or -not(Test-CcodStaticPackageMatch $probePackage $packageAfter) -or $targetAfter.CreationTimeUtc -cne $targetBefore.CreationTimeUtc){Throw-CcodStaticProbeError 'CCOD_STATIC_PACKAGE_CHANGED' 'The target package changed after probing' $null}
        $stage='RuntimePostflight';$after=Invoke-CcodStaticAdapter $adapter.ReauthorizeRuntime @($scriptPath) Single 'CCOD_STATIC_RUNTIME_UNAUTHORIZED';if(-not(Test-CcodStaticAuthorizationMatch $context $after)){Throw-CcodStaticProbeError 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' 'The active runtime changed during probing' $null}
        $stage='ResultValidation';$result=ConvertTo-CcodStaticProbePublicResult $task4 $request
    }catch{
        $code=Get-CcodStaticFailureForStage $stage $_;$result=New-CcodStaticProbeErrorResult $(if($requestValid){$request}else{$null}) $code $stage
    }
    if(-not $canPublish){return [pscustomobject][ordered]@{Result=$result;ExitCode=1}}
    try{
        Assert-CcodStaticProbeResult $result $(if($requestValid){$request}else{$null})|Out-Null
        $writeArguments=[Collections.Generic.List[object]]::new();$writeArguments.Add($ResultPath);$writeArguments.Add($result);if($null -ne $runtimeApi){$writeArguments.Add($runtimeApi)}
        Invoke-CcodStaticAdapter -Callback $adapter.WriteResult -ArgumentList $writeArguments.ToArray() -OutputMode None -ErrorId 'CCOD_STATIC_RESULT_INVALID'|Out-Null
    }catch{
        try{Invoke-CcodStaticAdapter $adapter.WriteStderr @('CCOD_STATIC_RESULT_WRITE_FAILED') None 'CCOD_STATIC_RESULT_INVALID'|Out-Null}catch{}
        return [pscustomobject][ordered]@{Result=(New-CcodStaticProbeErrorResult $(if($requestValid){$request}else{$null}) 'CCOD_STATIC_RESULT_INVALID' 'ResultValidation');ExitCode=1}
    }
    $line=$result|ConvertTo-Json -Depth 20 -Compress
    try{Invoke-CcodStaticAdapter $adapter.WriteStdout @($line) None 'CCOD_STATIC_RESULT_INVALID'|Out-Null}catch{return [pscustomobject][ordered]@{Result=$result;ExitCode=1}}
    return [pscustomobject][ordered]@{Result=$result;ExitCode=$(if($result.ok){0}else{1})}
}

if($MyInvocation.InvocationName -ne '.'){
    $run=Invoke-CcodStaticProbeWorker -RequestPath $RequestPath -ResultPath $ResultPath
    exit $run.ExitCode
}
