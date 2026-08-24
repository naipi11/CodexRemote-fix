[CmdletBinding()]
param(
    [ValidateRange(0,65535)][int]$RendererDebugPort=0,
    [ValidateRange(0,65535)][int]$MainInspectorPort=0,
    [ValidateRange(10,120)][int]$TimeoutSeconds=30,
    [switch]$RestartCodex
)

$ErrorActionPreference='Stop'
$runtimeManifestModule=Join-Path $PSScriptRoot 'src\persistence\modules\RuntimeManifest.psm1'
if(-not (Test-Path -LiteralPath $runtimeManifestModule -PathType Leaf)){throw 'CodexRemote-fix support files are incomplete. Run the installer from a complete checkout.'}
Import-Module $runtimeManifestModule -Force
$script:CcodRestartSubmissionReceiptFields=@('schemaVersion','submissionId','accepted','transactionId','errorCode','completedAtUtc')

function Test-CcodRestartCanonicalGuid {
    param($Value)
    $parsed=[guid]::Empty
    return $Value-is[string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D')-ceq$Value
}

function Test-CcodRestartCanonicalUtc {
    param($Value)
    $parsed=[DateTime]::MinValue
    return $Value-is[string] -and [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind-eq[DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-ceq$Value
}

function Assert-CcodRestartSubmissionReceipt {
    param($Receipt)
    if($Receipt-isnot[pscustomobject]){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Lifecycle submission receipt is invalid.'),'CCOD_RESTART_RECEIPT_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)}
    $actual=@($Receipt.PSObject.Properties.Name)
    if(($actual-join"`0")-cne($script:CcodRestartSubmissionReceiptFields-join"`0") -or
        @($Receipt.PSObject.Properties|Where-Object{$_.MemberType-notin@('NoteProperty','Property')}).Count-ne0 -or
        $Receipt.schemaVersion-isnot[int] -or $Receipt.schemaVersion-ne 1 -or
        -not(Test-CcodRestartCanonicalGuid $Receipt.submissionId) -or $Receipt.accepted-isnot[bool] -or
        -not(Test-CcodRestartCanonicalUtc $Receipt.completedAtUtc) -or
        ($Receipt.accepted -and (-not(Test-CcodRestartCanonicalGuid $Receipt.transactionId) -or $null-ne$Receipt.errorCode)) -or
        (-not$Receipt.accepted -and ($null-ne$Receipt.transactionId -or $Receipt.errorCode-isnot[string] -or $Receipt.errorCode-cnotmatch'^CCOD_[A-Z0-9_]{1,96}$'))){
        throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Lifecycle submission receipt is invalid.'),'CCOD_RESTART_RECEIPT_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
    }
    return $Receipt
}

function Resolve-CcodStartInstalledController {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $activePath=Join-Path $InstallRoot 'active.json'
    if(-not (Test-Path -LiteralPath $activePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('CodexRemote-fix is not installed. Run Install-CodexControlOtherDevices.ps1 first; this checkout wrapper will not create persistent checkout state.'),'CCOD_INSTALL_REQUIRED',[Management.Automation.ErrorCategory]::ObjectNotFound,$InstallRoot)}
    $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot
    $runtime=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
    $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $active.activeRuntime
    if(-not $validation.Valid){throw "Installed runtime validation failed: $($validation.Code). Repair or reinstall CodexRemote-fix."}
    $controller=Join-Path $runtime 'src\persistence\SessionController.ps1'
    if(-not (Test-Path -LiteralPath $controller -PathType Leaf)){throw 'The verified active runtime does not contain the required restart files. Repair or reinstall.'}
    $lifecycleRequestModule=Join-Path $runtime 'src\persistence\modules\LifecycleRequest.psm1'
    if(-not(Test-Path -LiteralPath $lifecycleRequestModule -PathType Leaf)){throw 'The verified active runtime lacks lifecycle submission support. Repair or reinstall.'}
    [pscustomobject]@{RuntimeId=$active.activeRuntime;Generation=[UInt64]$active.generation;RuntimeRoot=$runtime;Controller=[IO.Path]::GetFullPath($controller);LifecycleRequestModule=[IO.Path]::GetFullPath($lifecycleRequestModule)}
}

function Get-CcodStartSupervisorIdentity {
    $process=[Diagnostics.Process]::GetCurrentProcess()
    try{$created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$sessionId=[string]$process.SessionId}finally{$process.Dispose()}
    [pscustomobject][ordered]@{pid=$PID;creationTimeUtc=$created;sessionId=$sessionId}
}

function New-CcodStartControllerRequest {
    param([string]$RuntimeId,[int]$RendererDebugPort,[int]$MainInspectorPort,[int]$TimeoutSeconds,$SupervisorIdentity=(Get-CcodStartSupervisorIdentity),[string]$TransactionId=([guid]::NewGuid().ToString('D')))
    [pscustomobject][ordered]@{
        schemaVersion=1;action='Apply';transactionId=$TransactionId;runtimeId=$RuntimeId;supervisorIdentity=$SupervisorIdentity;source=$null;existingOnly=$false
        rendererPort=if($RendererDebugPort -eq 0){$null}else{$RendererDebugPort};mainPort=if($MainInspectorPort -eq 0){$null}else{$MainInspectorPort}
        timeoutMilliseconds=[int]($TimeoutSeconds*1000);restartOrdinary=$true
    }
}

function New-CcodStartControllerArguments {
    param([string]$Controller,[string]$RequestPath,[string]$ResultPath)
    @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Controller,'-RequestPath',$RequestPath,'-ResultPath',$ResultPath)
}

function Invoke-CcodStartInstalledController {
    param($Resolved,$Request)
    $powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
    $requestDirectory=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexControlOtherDevices'))
    [IO.Directory]::CreateDirectory($requestDirectory)|Out-Null
    $nonce=[guid]::NewGuid().ToString('N');$requestPath=[IO.Path]::GetFullPath((Join-Path $requestDirectory "start-$nonce-request.json"));$resultPath=[IO.Path]::GetFullPath((Join-Path $requestDirectory "start-$nonce-result.json"))
    $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-start-$([guid]::NewGuid().ToString('N')).err")))
    try{
        [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
        $resultPlaceholder=[IO.File]::Open($resultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$resultPlaceholder.Dispose()
        $arguments=New-CcodStartControllerArguments -Controller $Resolved.Controller -RequestPath $requestPath -ResultPath $resultPath
        $stdout=@(& $powershell @arguments 2>$stderrPath);$exitCode=$LASTEXITCODE
        $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        if($lines.Count -ne 1 -or -not [IO.File]::Exists($resultPath)){throw 'Installed controller did not return one persisted machine-readable result.'}
        try{$fromStdout=$lines[0]|ConvertFrom-Json -ErrorAction Stop;$result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Installed controller returned invalid JSON.'}
        if(($fromStdout|ConvertTo-Json -Depth 16 -Compress) -cne ($result|ConvertTo-Json -Depth 16 -Compress) -or $result.transactionId -cne $Request.transactionId -or $result.action -cne $Request.action -or $result.outcome -isnot [string]){throw 'Installed controller result is incomplete or uncorrelated.'}
        if($exitCode -ne 0 -or $result.ok -ne $true){throw "Session $($Request.action) failed safely: $($result.error.code) $($result.error.message)"}
        return $result
    }finally{
        foreach($path in @($requestPath,$resultPath,$stderrPath)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
    }
}

function Submit-CcodStartRestart {
    param($Resolved,[Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][int]$TimeoutMilliseconds)
    Import-Module $Resolved.LifecycleRequestModule -Force
    $untrustedReceipt=Submit-CcodLifecycleRequest -InstallRoot $InstallRoot -Kind RestartAndRepair -Origin ExplicitStart -RuntimeId $Resolved.RuntimeId -RuntimeGeneration ([UInt64]$Resolved.Generation) -TimeoutMilliseconds $TimeoutMilliseconds
    Assert-CcodRestartSubmissionReceipt -Receipt $untrustedReceipt
}

if($MyInvocation.InvocationName -ne '.'){
    $installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexControlOtherDevices'))
    $resolved=Resolve-CcodStartInstalledController -InstallRoot $installRoot
    if($RestartCodex){
        $receipt=Submit-CcodStartRestart -Resolved $resolved -InstallRoot $installRoot -TimeoutMilliseconds ([int]($TimeoutSeconds*1000))
        if(-not$receipt.accepted){throw "CCOD_RESTART_SUBMISSION_REJECTED: $($receipt.errorCode)"}
        Write-Host ''
        Write-Host 'Codex restart and repair was submitted to the persistent Supervisor.' -ForegroundColor Green
        Write-Host ("Transaction: {0}" -f $receipt.transactionId)
        Write-Host ''
    }else{
        $request=New-CcodStartControllerRequest -RuntimeId $resolved.RuntimeId -RendererDebugPort $RendererDebugPort -MainInspectorPort $MainInspectorPort -TimeoutSeconds $TimeoutSeconds
        $result=Invoke-CcodStartInstalledController -Resolved $resolved -Request $request
        Write-Host ''
        Write-Host 'CodexRemote-fix is enabled for this app session.' -ForegroundColor Green
        Write-Host 'Open Settings > Connections > Control other devices.'
        if($null -ne $result.logFile){Write-Host "Diagnostics: $($result.logFile)"}
        Write-Host 'Launch Codex normally or run Reset-CodexControlOtherDevices.ps1 to disable the runtime fix.'
        Write-Host ''
    }
}
