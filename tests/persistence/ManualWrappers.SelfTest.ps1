$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$startPath=Join-Path $repositoryRoot 'Start-CodexControlOtherDevices.ps1';$resetPath=Join-Path $repositoryRoot 'Reset-CodexControlOtherDevices.ps1'
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
. $startPath
. $resetPath

function Get-CcodScriptAst([string]$Path){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);if($errors.Count -ne 0){throw ($errors|Out-String)};return $ast}

function New-CcodFakeFileModeController([string]$Path){
    $source=@'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$expected='schemaVersion,action,transactionId,runtimeId,supervisorIdentity,source,existingOnly,rendererPort,mainPort,timeoutMilliseconds,restartOrdinary'
if(($request.PSObject.Properties.Name -join ',') -cne $expected -or $request.existingOnly -isnot [bool] -or $request.restartOrdinary -isnot [bool]){exit 7}
$outcome=if($request.action -ceq 'Apply'){'Activated'}elseif($request.restartOrdinary){'Recovered'}else{'Closed'}
$safe=if($outcome -ceq 'Activated'){'SpecialValidated'}elseif($outcome -ceq 'Closed'){'Closed'}else{'OrdinaryRunning'}
$result=[pscustomobject][ordered]@{schemaVersion=1;action=$request.action;ok=$true;outcome=$outcome;safeState=$safe;stage='Completed';transactionId=$request.transactionId;package=$null;source=[pscustomobject][ordered]@{existingOnly=$request.existingOnly;restartOrdinary=$request.restartOrdinary;timeoutMilliseconds=$request.timeoutMilliseconds;rendererPort=$request.rendererPort;mainPort=$request.mainPort};special=$null;probes=$null;recovery=$null;error=$null;logFile=$null}
$json=$result|ConvertTo-Json -Depth 16 -Compress
[IO.File]::WriteAllText($ResultPath,$json,[Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine($json)
'@
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent))|Out-Null
    [IO.File]::WriteAllText($Path,$source,[Text.UTF8Encoding]::new($false))
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-wrapper-selftest-'+[guid]::NewGuid().ToString('N'))
try{
    Invoke-CcodTest 'keeps exact public parameters and contains no process bridge or kill implementation' {
        $startAst=Get-CcodScriptAst $startPath;$resetAst=Get-CcodScriptAst $resetPath
        Assert-CcodEqual 'RendererDebugPort,MainInspectorPort,TimeoutSeconds,RestartCodex' (($startAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath}) -join ',') 'Start exposes an explicit installer-approved Codex restart option'
        Assert-CcodEqual 'BackupDeviceKeyStore,DoNotRestart' (($resetAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath}) -join ',') 'Reset public parameters remain exact'
        foreach($case in @(@{Name='Start';Ast=$startAst},@{Name='Reset';Ast=$resetAst})){
            $commands=@($case.Ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
            foreach($forbidden in @('Get-Process','Stop-Process','Start-Process','Get-AppxPackage')){Assert-CcodTrue ($commands -cnotcontains $forbidden) "$($case.Name) wrapper has no $forbidden workflow"}
            $text=$case.Ast.Extent.Text;Assert-CcodTrue ($text -cnotmatch 'orchestrator\.js|main-payload|remote-debugging|--inspect') "$($case.Name) wrapper has no bridge implementation"
        }
    }

    Invoke-CcodTest 'maps public Start and Reset values into exact typed file-mode requests' {
        $identity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        $automatic=New-CcodStartControllerRequest -RuntimeId 'runtime-1' -RendererDebugPort 0 -MainInspectorPort 0 -TimeoutSeconds 120 -SupervisorIdentity $identity -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        Assert-CcodEqual 'schemaVersion,action,transactionId,runtimeId,supervisorIdentity,source,existingOnly,rendererPort,mainPort,timeoutMilliseconds,restartOrdinary' (($automatic.PSObject.Properties.Name)-join ',') 'Start request has the strict eleven fields'
        Assert-CcodEqual $false $automatic.existingOnly 'Start explicitly allows a closed app with a real JSON false'
        Assert-CcodEqual $null $automatic.rendererPort 'public zero renderer port maps to null'
        Assert-CcodEqual $null $automatic.mainPort 'public zero main port maps to null'
        Assert-CcodEqual 120000 $automatic.timeoutMilliseconds 'public 120 seconds is preserved exactly'

        $explicit=New-CcodStartControllerRequest -RuntimeId 'runtime-1' -RendererDebugPort 41001 -MainInspectorPort 41002 -TimeoutSeconds 61 -SupervisorIdentity $identity -TransactionId 'f81b6259-8e99-45fb-b557-c5292f05dfa3'
        Assert-CcodEqual 41001 $explicit.rendererPort 'explicit public renderer port is preserved'
        Assert-CcodEqual 41002 $explicit.mainPort 'explicit public main port is preserved'
        Assert-CcodEqual 61000 $explicit.timeoutMilliseconds 'public 61 seconds survives request creation'

        $normal=New-CcodResetControllerRequest -RuntimeId 'runtime-1' -DoNotRestart $false -SupervisorIdentity $identity -TransactionId '30fc56b0-547b-4b60-996a-d82b7301384c'
        Assert-CcodEqual $true $normal.restartOrdinary 'normal Reset requests ordinary recovery with a real JSON true'
        $closed=New-CcodResetControllerRequest -RuntimeId 'runtime-1' -DoNotRestart $true -SupervisorIdentity $identity -TransactionId 'b56470ad-948a-4df7-b5f2-04a4df86a256'
        Assert-CcodEqual $false $closed.restartOrdinary 'DoNotRestart maps to a real JSON false'

        $arguments=New-CcodStartControllerArguments -Controller 'C:\installed\SessionController.ps1' -RequestPath 'C:\request.json' -ResultPath 'C:\result.json'
        Assert-CcodEqual '-NoProfile,-ExecutionPolicy,Bypass,-File,C:\installed\SessionController.ps1,-RequestPath,C:\request.json,-ResultPath,C:\result.json' ($arguments -join ',') 'child arguments carry only file paths, never Boolean text'

        $restart=New-CcodRestartControllerRequest -RuntimeId 'runtime-1' -TimeoutSeconds 45 -SupervisorIdentity $identity -TransactionId 'ebd973bd-9b64-4cf3-a282-d080be72ff34'
        Assert-CcodEqual 'Recover' $restart.action 'explicit restart first closes the verified current Codex session'
        Assert-CcodEqual $true $restart.existingOnly 'explicit restart never adopts an unrelated closed-app session'
        Assert-CcodEqual $true $restart.restartOrdinary 'explicit restart uses the verified recovery path before controlled reactivation'
        Assert-CcodEqual 45000 $restart.timeoutMilliseconds 'explicit restart keeps its caller timeout'
    }

    Invoke-CcodTest 'real powershell file-mode children receive Boolean JSON without parameter binding failures' {
        $controller=Join-Path $root 'fake-runtime\SessionController.ps1';New-CcodFakeFileModeController $controller
        $resolved=[pscustomobject]@{RuntimeId='runtime-1';Controller=[IO.Path]::GetFullPath($controller)}
        $identity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        $startRequest=New-CcodStartControllerRequest -RuntimeId 'runtime-1' -RendererDebugPort 41001 -MainInspectorPort 41002 -TimeoutSeconds 120 -SupervisorIdentity $identity -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        $start=Invoke-CcodStartInstalledController -Resolved $resolved -Request $startRequest
        Assert-CcodEqual $false $start.source.existingOnly 'Start false crossed the real powershell.exe child as Boolean'
        Assert-CcodEqual $true $start.source.restartOrdinary 'Start true crossed the real powershell.exe child as Boolean'
        Assert-CcodEqual 120000 $start.source.timeoutMilliseconds '120 seconds crossed the real child unchanged'

        $resetRequest=New-CcodResetControllerRequest -RuntimeId 'runtime-1' -DoNotRestart $true -SupervisorIdentity $identity -TransactionId 'b56470ad-948a-4df7-b5f2-04a4df86a256'
        $reset=Invoke-CcodResetInstalledController -Resolved $resolved -Request $resetRequest
        Assert-CcodEqual $false $reset.source.restartOrdinary 'Reset DoNotRestart false crossed the real powershell.exe child as Boolean'

        $restartRequest=New-CcodRestartControllerRequest -RuntimeId 'runtime-1' -TimeoutSeconds 45 -SupervisorIdentity $identity -TransactionId 'ebd973bd-9b64-4cf3-a282-d080be72ff34'
        $restartWorkflow=Invoke-CcodRestartInstalledWorkflow -Resolved $resolved -RestartRequest $restartRequest -ApplyRequest $startRequest
        Assert-CcodEqual 'Recovered' $restartWorkflow.Recovery.outcome 'explicit restart proves an ordinary recovery before reactivation'
        Assert-CcodEqual 'Activated' $restartWorkflow.Apply.outcome 'explicit restart reactivates the controlled Codex session through the verified controller'
    }

    Invoke-CcodTest 'keeps a successful reset successful when the optional device-key backup fails' {
        $calls=[pscustomobject]@{Controller=0;Backup=0}
        $resolved=[pscustomobject]@{RuntimeId='runtime-1';Controller='C:\installed\SessionController.ps1';StateModule='C:\installed\StateStore.psm1'}
        $request=New-CcodResetControllerRequest -RuntimeId 'runtime-1' -DoNotRestart $false -SupervisorIdentity ([pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'})
        $workflow=Invoke-CcodResetWorkflow -Resolved $resolved -Request $request -BackupDeviceKeyStore $true `
            -ControllerInvoker {param($Resolved,$Request)$calls.Controller++;[pscustomobject]@{ok=$true;outcome='Recovered';transactionId=$Request.transactionId}}.GetNewClosure() `
            -BackupMover {param($StateModule)$calls.Backup++;throw "C:\secret\device-key.json`n--token hunter2"}.GetNewClosure()
        Assert-CcodEqual 'Recovered' $workflow.Result.outcome 'the already successful controller result is retained'
        Assert-CcodEqual $null $workflow.BackupPath 'a failed optional backup reports no invented path'
        Assert-CcodEqual 'The session reset succeeded, but the optional device-key backup could not be completed.' $workflow.Warning 'backup failure returns only a fixed non-secret warning'
        Assert-CcodTrue ($workflow.Warning -cnotmatch 'secret|hunter2|[\r\n]') 'backup warning never publishes raw exception data'
        Assert-CcodEqual 1 $calls.Controller 'backup failure never retries the controller operation'
        Assert-CcodEqual 1 $calls.Backup 'the optional backup is attempted only once'
    }

    Invoke-CcodTest 'fails clearly in checkout-only mode before creating durable state' {
        $installRoot=Join-Path $root 'not-installed'
        Assert-CcodThrows {Resolve-CcodStartInstalledController -InstallRoot $installRoot} 'CCOD_INSTALL_REQUIRED'
        Assert-CcodThrows {Resolve-CcodResetInstalledController -InstallRoot $installRoot} 'CCOD_INSTALL_REQUIRED'
        Assert-CcodEqual $false (Test-Path -LiteralPath $installRoot) 'checkout-only failure creates no install state'
    }

    Invoke-CcodTest 'dispatches only to a manifest-verified active runtime' {
        $installRoot=Join-Path $root 'installed';$staging=Join-Path $installRoot 'staging';$controller=Join-Path $staging 'src\persistence\SessionController.ps1';$stateModule=Join-Path $staging 'src\persistence\modules\StateStore.psm1'
        [IO.Directory]::CreateDirectory((Split-Path $controller -Parent))|Out-Null;[IO.Directory]::CreateDirectory((Split-Path $stateModule -Parent))|Out-Null
        [IO.File]::WriteAllText($controller,'# installed controller',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stateModule,'# installed state',[Text.UTF8Encoding]::new($false))
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion '2.0.0';$runtime=Join-Path (Join-Path $installRoot 'runtime') $manifest.runtimeId;[IO.Directory]::CreateDirectory((Split-Path $runtime -Parent))|Out-Null;[IO.Directory]::Move($staging,$runtime)
        [IO.File]::WriteAllText((Join-Path $runtime 'manifest.json'),($manifest|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'),(([ordered]@{schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[UInt64]1;updatedAtUtc='2030-02-03T04:05:06.0000000Z'}|ConvertTo-Json -Depth 5)),[Text.UTF8Encoding]::new($false))
        $start=Resolve-CcodStartInstalledController -InstallRoot $installRoot;$reset=Resolve-CcodResetInstalledController -InstallRoot $installRoot
        Assert-CcodEqual ([IO.Path]::GetFullPath((Join-Path $runtime 'src\persistence\SessionController.ps1'))) $start.Controller 'Start targets verified active controller'
        Assert-CcodEqual $start.Controller $reset.Controller 'Reset targets the same verified runtime'
        Assert-CcodEqual $null $start.PSObject.Properties['ProcessControl'] 'Start uses only the verified controller and cannot bypass its recovery protocol'
        [IO.File]::AppendAllText($start.Controller,'tampered',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Resolve-CcodStartInstalledController -InstallRoot $installRoot} '*'
    }
}catch{Write-Error $_;exit 1}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
