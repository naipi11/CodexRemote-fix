$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$resetPath=Join-Path $repositoryRoot 'Reset-CodexControlOtherDevices.ps1'
$startPath=Join-Path $repositoryRoot 'Start-CodexControlOtherDevices.ps1'
. $resetPath

function New-CcodFakeLifecycleRequestModule([string]$Path,[string]$CapturePath){
    $source=@"
function Submit-CcodLifecycleRequest {
    param(`$InstallRoot,`$Kind,`$Origin,`$RuntimeId,`$RuntimeGeneration,`$TimeoutMilliseconds)
    [IO.File]::WriteAllText('$CapturePath',(( [ordered]@{InstallRoot=`$InstallRoot;Kind=`$Kind;Origin=`$Origin;RuntimeId=`$RuntimeId;RuntimeGeneration=[UInt64]`$RuntimeGeneration;TimeoutMilliseconds=`$TimeoutMilliseconds})|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
    [pscustomobject][ordered]@{accepted=`$true;transactionId='11111111-2222-3333-4444-555555555555';errorCode=`$null}
}

Export-ModuleMember -Function Submit-CcodLifecycleRequest
"@
    [IO.File]::WriteAllText($Path,$source,[Text.UTF8Encoding]::new($false))
}

Invoke-CcodTest 'Start retains its public contract and a manifest-bound controller boundary' {
    # Production mutation caught: adding hidden public controls or bypassing active-runtime manifest validation.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($startPath,[ref]$tokens,[ref]$errors)
    Assert-CcodTrue (@($errors).Count -eq 0) 'Start wrapper parses'
    Assert-CcodEqual 'RendererDebugPort,MainInspectorPort,TimeoutSeconds,RestartCodex' (($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})-join ',') 'Start retains the frozen public parameters'
    $commands=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($forbidden in @('Get-Process','Stop-Process','Start-Process','Get-AppxPackage')){Assert-CcodTrue ($commands-cnotcontains$forbidden) "Start has no direct $forbidden mutation"}
    Assert-CcodTrue ($commands-ccontains'Test-CcodRuntimeManifest') 'Start resolves through manifest verification'
}

Invoke-CcodTest 'Reset is a submit-only SafeExit compatibility alias' {
    # Production mutation caught: bypassing the durable lifecycle inbox or calling SessionController directly.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($resetPath,[ref]$tokens,[ref]$errors)
    Assert-CcodTrue (@($errors).Count -eq 0) 'Reset wrapper parses'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    Assert-CcodTrue ($commands -ccontains 'Submit-CcodLifecycleRequest') 'Reset submits the durable lifecycle request'
    foreach($forbidden in @('SessionController.ps1','Move-Item','Copy-Item','Remove-Item')){Assert-CcodTrue ($commands -cnotcontains $forbidden) "Reset never invokes $forbidden"}
    $source=Get-Content -LiteralPath $resetPath -Raw -Encoding UTF8
    Assert-CcodTrue ($source -cmatch "-Kind SafeExit") 'Reset submits SafeExit'
}

Invoke-CcodTest 'Reset rejects the removed BackupDeviceKeyStore option without moving the key store' {
    # Production mutation caught: restoring key-store backup/move behavior behind the compatibility switch.
    $failure=$null;try{& $resetPath -BackupDeviceKeyStore}catch{$failure=$_};$text=[string]$failure
    Assert-CcodTrue ($text -cmatch 'CCOD_RESET_BACKUP_REMOVED') 'removed option returns a stable migration code'
    Assert-CcodTrue ($text -cmatch 'preserved in place') 'migration message states that the device key remains in place'
}

Invoke-CcodTest 'Reset submits an accepted manifest-bound SafeExit receipt' {
    # Production mutation caught: submitting a legacy controller action, a stale runtime generation, or treating a rejected receipt as accepted.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-reset-'+[guid]::NewGuid().ToString('N'))
    try{
        [IO.Directory]::CreateDirectory($root)|Out-Null;$modulePath=Join-Path $root 'LifecycleRequest.psm1';$capture=Join-Path $root 'capture.json'
        New-CcodFakeLifecycleRequestModule $modulePath $capture
        $resolved=[pscustomobject][ordered]@{RuntimeId='2.5.0-runtime';Generation=[UInt64]9;ModulePath=$modulePath}
        $receipt=Submit-CcodResetSafeExit -Resolved $resolved -InstallRoot $root
        $submission=Get-Content -LiteralPath $capture -Raw|ConvertFrom-Json
        Assert-CcodTrue $receipt.accepted 'accepted lifecycle receipt is returned to the wrapper caller'
        Assert-CcodEqual 'SafeExit' $submission.Kind 'Reset submits SafeExit'
        Assert-CcodEqual '2.5.0-runtime' $submission.RuntimeId 'Reset uses the manifest-bound runtime id'
        Assert-CcodEqual 9 ([UInt64]$submission.RuntimeGeneration) 'Reset uses the manifest-bound generation'
    }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'Reset rejects DoNotRestart because SafeExit has no legacy restart toggle' {
    # Production mutation caught: accepting DoNotRestart while silently applying obsolete direct-controller semantics.
    $failure=$null;try{& $resetPath -DoNotRestart}catch{$failure=$_}
    Assert-CcodTrue (([string]$failure) -cmatch 'CCOD_RESET_DONOTRESTART_REMOVED') 'DoNotRestart returns a stable migration code'
}

Write-Host 'Manual wrapper self-tests passed.'
