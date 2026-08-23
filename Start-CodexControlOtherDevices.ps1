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
    [pscustomobject]@{RuntimeId=$active.activeRuntime;RuntimeRoot=$runtime;Controller=[IO.Path]::GetFullPath($controller)}
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

function New-CcodRestartControllerRequest {
    param([string]$RuntimeId,[int]$TimeoutSeconds,$SupervisorIdentity=(Get-CcodStartSupervisorIdentity),[string]$TransactionId=([guid]::NewGuid().ToString('D')))
    [pscustomobject][ordered]@{
        schemaVersion=1;action='Recover';transactionId=$TransactionId;runtimeId=$RuntimeId;supervisorIdentity=$SupervisorIdentity;source=$null;existingOnly=$true
        rendererPort=$null;mainPort=$null;timeoutMilliseconds=[int]($TimeoutSeconds*1000);restartOrdinary=$true
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

function Invoke-CcodRestartInstalledWorkflow {
    param($Resolved,$RestartRequest,$ApplyRequest)
    $recovery=Invoke-CcodStartInstalledController -Resolved $Resolved -Request $RestartRequest
    if($recovery.outcome -notin @('Recovered','NoAction','Closed')){throw "Codex restart could not safely recover the current session: $($recovery.outcome)"}
    $apply=Invoke-CcodStartInstalledController -Resolved $Resolved -Request $ApplyRequest
    if($apply.outcome -notin @('Activated','NoAction')){throw "Codex restart did not activate the controlled session: $($apply.outcome)"}
    return [pscustomobject][ordered]@{Recovery=$recovery;Apply=$apply}
}

if($MyInvocation.InvocationName -ne '.'){
    $installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexControlOtherDevices'))
    $resolved=Resolve-CcodStartInstalledController -InstallRoot $installRoot
    $request=New-CcodStartControllerRequest -RuntimeId $resolved.RuntimeId -RendererDebugPort $RendererDebugPort -MainInspectorPort $MainInspectorPort -TimeoutSeconds $TimeoutSeconds
    if($RestartCodex){
        $restart=New-CcodRestartControllerRequest -RuntimeId $resolved.RuntimeId -TimeoutSeconds $TimeoutSeconds
        $workflow=Invoke-CcodRestartInstalledWorkflow -Resolved $resolved -RestartRequest $restart -ApplyRequest $request
        $result=$workflow.Apply
    }else{
        $result=Invoke-CcodStartInstalledController -Resolved $resolved -Request $request
    }
    Write-Host ''
    Write-Host 'CodexRemote-fix is enabled for this app session.' -ForegroundColor Green
    Write-Host 'Open Settings > Connections > Control other devices.'
    if($null -ne $result.logFile){Write-Host "Diagnostics: $($result.logFile)"}
    Write-Host 'Launch Codex normally or run Reset-CodexControlOtherDevices.ps1 to disable the runtime fix.'
    Write-Host ''
}
