[CmdletBinding()]
param(
    [switch]$BackupDeviceKeyStore,
    [switch]$DoNotRestart
)

$ErrorActionPreference='Stop'
$runtimeManifestModule=Join-Path $PSScriptRoot 'src\persistence\modules\RuntimeManifest.psm1'
if(-not (Test-Path -LiteralPath $runtimeManifestModule -PathType Leaf)){throw 'CodexRemote-fix support files are incomplete. Run the installer from a complete checkout.'}
Import-Module $runtimeManifestModule -Force

function Resolve-CcodResetInstalledController {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $activePath=Join-Path $InstallRoot 'active.json'
    if(-not (Test-Path -LiteralPath $activePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('CodexRemote-fix is not installed. Run Install-CodexControlOtherDevices.ps1 first; this checkout wrapper will not create persistent checkout state.'),'CCOD_INSTALL_REQUIRED',[Management.Automation.ErrorCategory]::ObjectNotFound,$InstallRoot)}
    $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot;$runtime=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
    $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $active.activeRuntime
    if(-not $validation.Valid){throw "Installed runtime validation failed: $($validation.Code). Repair or reinstall CodexRemote-fix."}
    $controller=Join-Path $runtime 'src\persistence\SessionController.ps1';$stateModule=Join-Path $runtime 'src\persistence\modules\StateStore.psm1'
    if(-not (Test-Path -LiteralPath $controller -PathType Leaf) -or -not (Test-Path -LiteralPath $stateModule -PathType Leaf)){throw 'The verified active runtime lacks required reset files. Repair or reinstall.'}
    [pscustomobject]@{RuntimeId=$active.activeRuntime;Controller=[IO.Path]::GetFullPath($controller);StateModule=[IO.Path]::GetFullPath($stateModule)}
}

function Get-CcodResetSupervisorIdentity {
    $process=[Diagnostics.Process]::GetCurrentProcess()
    try{$created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$sessionId=[string]$process.SessionId}finally{$process.Dispose()}
    [pscustomobject][ordered]@{pid=$PID;creationTimeUtc=$created;sessionId=$sessionId}
}

function New-CcodResetControllerRequest {
    param([string]$RuntimeId,[bool]$DoNotRestart,$SupervisorIdentity=(Get-CcodResetSupervisorIdentity),[string]$TransactionId=([guid]::NewGuid().ToString('D')))
    [pscustomobject][ordered]@{schemaVersion=1;action='Recover';transactionId=$TransactionId;runtimeId=$RuntimeId;supervisorIdentity=$SupervisorIdentity;source=$null;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=30000;restartOrdinary=(-not $DoNotRestart)}
}

function New-CcodResetControllerArguments {
    param([string]$Controller,[string]$RequestPath,[string]$ResultPath)
    @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Controller,'-RequestPath',$RequestPath,'-ResultPath',$ResultPath)
}

function Invoke-CcodResetInstalledController {
    param($Resolved,$Request)
    $powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
    $requestDirectory=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexControlOtherDevices'))
    [IO.Directory]::CreateDirectory($requestDirectory)|Out-Null
    $nonce=[guid]::NewGuid().ToString('N');$requestPath=[IO.Path]::GetFullPath((Join-Path $requestDirectory "reset-$nonce-request.json"));$resultPath=[IO.Path]::GetFullPath((Join-Path $requestDirectory "reset-$nonce-result.json"))
    $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-reset-$([guid]::NewGuid().ToString('N')).err")))
    try{
        [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
        $resultPlaceholder=[IO.File]::Open($resultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$resultPlaceholder.Dispose()
        $arguments=New-CcodResetControllerArguments -Controller $Resolved.Controller -RequestPath $requestPath -ResultPath $resultPath
        $stdout=@(& $powershell @arguments 2>$stderrPath);$exitCode=$LASTEXITCODE
        $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        if($lines.Count -ne 1 -or -not [IO.File]::Exists($resultPath)){throw 'Installed controller did not return one persisted machine-readable result.'}
        try{$fromStdout=$lines[0]|ConvertFrom-Json -ErrorAction Stop;$result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Installed controller returned invalid JSON.'}
        if(($fromStdout|ConvertTo-Json -Depth 16 -Compress) -cne ($result|ConvertTo-Json -Depth 16 -Compress) -or $result.transactionId -cne $Request.transactionId -or $result.action -cne 'Recover' -or $result.outcome -isnot [string]){throw 'Installed controller result is incomplete or uncorrelated.'}
        if($exitCode -ne 0 -or $result.ok -ne $true){throw "Session reset failed safely: $($result.error.code) $($result.error.message)"}
        return $result
    }finally{
        foreach($path in @($requestPath,$resultPath,$stderrPath)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
    }
}

function Move-CcodResetDeviceKeyStore {
    param([string]$StateModule)
    Import-Module $StateModule -Force;$store=Resolve-CcodDeviceKeyStorePath
    if(-not (Test-Path -LiteralPath $store -PathType Leaf)){return $null}
    $base="$store.backup.$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))";$destination=$base;$suffix=0
    while(Test-Path -LiteralPath $destination){$suffix++;$destination="$base.$suffix"}
    Move-Item -LiteralPath $store -Destination $destination
    return $destination
}

function Invoke-CcodResetWorkflow {
    param(
        $Resolved,
        $Request,
        [bool]$BackupDeviceKeyStore,
        [scriptblock]$ControllerInvoker={param($ResolvedValue,$RequestValue)Invoke-CcodResetInstalledController -Resolved $ResolvedValue -Request $RequestValue},
        [scriptblock]$BackupMover={param($StateModule)Move-CcodResetDeviceKeyStore -StateModule $StateModule}
    )
    $result=& $ControllerInvoker $Resolved $Request
    $backupPath=$null;$warning=$null
    if($BackupDeviceKeyStore){
        try{$backupPath=& $BackupMover $Resolved.StateModule}
        catch{$warning='The session reset succeeded, but the optional device-key backup could not be completed.'}
    }
    [pscustomobject][ordered]@{Result=$result;BackupPath=$backupPath;Warning=$warning}
}

if($MyInvocation.InvocationName -ne '.'){
    $installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexControlOtherDevices'))
    $resolved=Resolve-CcodResetInstalledController -InstallRoot $installRoot;$request=New-CcodResetControllerRequest -RuntimeId $resolved.RuntimeId -DoNotRestart ([bool]$DoNotRestart)
    $workflow=Invoke-CcodResetWorkflow -Resolved $resolved -Request $request -BackupDeviceKeyStore ([bool]$BackupDeviceKeyStore)
    $result=$workflow.Result;$backup=$workflow.BackupPath
    Write-Host ''
    Write-Host 'The runtime fix is no longer active.' -ForegroundColor Green
    if($backup){Write-Host "The encrypted device-key store was moved to: $backup";Write-Host 'This local move does not revoke server-side authorization; revoke the device in Codex first.' -ForegroundColor Yellow}
    if($workflow.Warning){Write-Warning $workflow.Warning}
    if($DoNotRestart){Write-Host 'Codex Desktop was left closed.'}else{Write-Host 'Codex Desktop was returned to an ordinary session.'}
    Write-Host ''
}
