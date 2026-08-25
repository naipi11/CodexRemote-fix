$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$resetPath=Join-Path $repositoryRoot 'Reset-CodexControlOtherDevices.ps1'
$startPath=Join-Path $repositoryRoot 'Start-CodexControlOtherDevices.ps1'
$promptPath=Join-Path $repositoryRoot 'Prompt-CcodRestart.ps1'
$uninstallPath=Join-Path $repositoryRoot 'Uninstall-CodexControlOtherDevices.ps1'
. $resetPath
. $startPath

function New-CcodFakeLifecycleRequestModule([string]$Path,[string]$CapturePath){
    $source=@"
function Submit-CcodLifecycleRequest {
    param(`$InstallRoot,`$Kind,`$Origin,`$RuntimeId,`$RuntimeGeneration,`$TimeoutMilliseconds)
    [IO.File]::WriteAllText('$CapturePath',(( [ordered]@{InstallRoot=`$InstallRoot;Kind=`$Kind;Origin=`$Origin;RuntimeId=`$RuntimeId;RuntimeGeneration=[UInt64]`$RuntimeGeneration;TimeoutMilliseconds=`$TimeoutMilliseconds})|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
    [pscustomobject][ordered]@{schemaVersion=1;submissionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';accepted=`$true;transactionId='11111111-2222-3333-4444-555555555555';errorCode=`$null;completedAtUtc='2030-02-03T04:05:06.0000000Z'}
}

Export-ModuleMember -Function Submit-CcodLifecycleRequest
"@
    [IO.File]::WriteAllText($Path,$source,[Text.UTF8Encoding]::new($false))
}

function New-CcodFakeLifecycleReceiptModule([string]$Path,$Receipt){
    $json=($Receipt|ConvertTo-Json -Depth 8 -Compress).Replace("'","''")
    $source=@"
function Submit-CcodLifecycleRequest {
    param(`$InstallRoot,`$Kind,`$Origin,`$RuntimeId,`$RuntimeGeneration,`$TimeoutMilliseconds)
    '$json'|ConvertFrom-Json
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

Invoke-CcodTest 'Start RestartCodex submits one accepted manifest-bound RestartAndRepair request' {
    # Production mutation caught: invoking direct Recover/Apply controllers, submitting twice, or dropping the active runtime generation/transaction receipt.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-start-restart-'+[guid]::NewGuid().ToString('N'))
    try{
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $modulePath=Join-Path $root 'LifecycleRequest.psm1';$capture=Join-Path $root 'capture.json'
        New-CcodFakeLifecycleRequestModule $modulePath $capture
        $resolved=[pscustomobject][ordered]@{RuntimeId='2.5.0-runtime';Generation=[UInt64]11;LifecycleRequestModule=$modulePath}
        $receipt=Submit-CcodStartRestart -Resolved $resolved -InstallRoot $root -TimeoutMilliseconds 5000
        $submission=Get-Content -LiteralPath $capture -Raw|ConvertFrom-Json
        Assert-CcodTrue $receipt.accepted 'accepted submission receipt returns to Start'
        Assert-CcodEqual '11111111-2222-3333-4444-555555555555' $receipt.transactionId 'Start receives the durable lifecycle transaction id'
        Assert-CcodEqual 'RestartAndRepair' $submission.Kind 'Start submits RestartAndRepair'
        Assert-CcodEqual 'ExplicitStart' $submission.Origin 'Start records an explicit wrapper origin'
        Assert-CcodEqual '2.5.0-runtime' $submission.RuntimeId 'Start binds the manifest runtime id'
        Assert-CcodEqual 11 ([UInt64]$submission.RuntimeGeneration) 'Start binds the active pointer generation'
    }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'Start RestartCodex rejects every malformed accepted submission receipt' {
    # Production mutation caught: checking only truthiness/accepted while trusting reordered, extra, noncanonical, or mistyped receipt data.
    $valid=[ordered]@{schemaVersion=1;submissionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';accepted=$true;transactionId='11111111-2222-3333-4444-555555555555';errorCode=$null;completedAtUtc='2030-02-03T04:05:06.0000000Z'}
    $cases=@(
        [pscustomobject]@{Name='truthy accepted';Mutate={param($r)$r.accepted='true'}},
        [pscustomobject]@{Name='noncanonical submission';Mutate={param($r)$r.submissionId='AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'}},
        [pscustomobject]@{Name='untrusted transaction';Mutate={param($r)$r.transactionId='ATTACKER_STDOUT_MARKER'}},
        [pscustomobject]@{Name='noncanonical completion time';Mutate={param($r)$r.completedAtUtc='2030-02-03T04:05:06Z'}},
        [pscustomobject]@{Name='extra field';Mutate={param($r)$r.attacker='ATTACKER_STDOUT_MARKER'}}
    )
    foreach($case in $cases){
        $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-start-invalid-receipt-'+[guid]::NewGuid().ToString('N'))
        try{
            [IO.Directory]::CreateDirectory($root)|Out-Null;$modulePath=Join-Path $root 'LifecycleRequest.psm1'
            $receipt=[ordered]@{};foreach($key in $valid.Keys){$receipt[$key]=$valid[$key]};&$case.Mutate $receipt
            New-CcodFakeLifecycleReceiptModule $modulePath $receipt
            $resolved=[pscustomobject][ordered]@{RuntimeId='2.5.0-runtime';Generation=[UInt64]11;LifecycleRequestModule=$modulePath}
            $failure=$null;$observed=@();try{$observed=@(Submit-CcodStartRestart -Resolved $resolved -InstallRoot $root -TimeoutMilliseconds 5000)}catch{$failure=$_}
            Assert-CcodTrue ($null-ne$failure) "$($case.Name) fails closed"
            Assert-CcodTrue ($failure.FullyQualifiedErrorId-like'CCOD_RESTART_RECEIPT_INVALID*') "$($case.Name) returns the bounded stable receipt code"
            Assert-CcodTrue (($observed-join"`n")-cnotmatch'ATTACKER_STDOUT_MARKER') "$($case.Name) emits no untrusted receipt data"
        }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
    }
}

Invoke-CcodTest 'restart prompt submits once through the verified runtime and logs correlated public identifiers' {
    # Production mutation caught: invoking Start/Recover/Apply, skipping manifest validation, submitting more than once, suppressing stderr, or losing activation/submission/transaction correlation.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-prompt-restart-'+[guid]::NewGuid().ToString('N'))
    try{
        $app=Join-Path $root 'app';$install=Join-Path $root 'install';$runtimeId='2.5.0-runtime';$runtime=Join-Path $install "runtime\$runtimeId"
        [IO.Directory]::CreateDirectory((Join-Path $app 'src\persistence\modules'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'src\persistence\modules'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'active.json'),'{"schemaVersion":2}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $app 'Start-CodexControlOtherDevices.ps1'),"[IO.File]::WriteAllText('$(Join-Path $root 'controller-called.txt')','called')",[Text.UTF8Encoding]::new($false))
        $manifestCapture=Join-Path $root 'manifest.json'
        $runtimeModule=@"
function Read-CcodActiveRuntime { param(`$InstallRoot) [pscustomobject][ordered]@{activeRuntime='$runtimeId';generation=[UInt64]7} }
function Test-CcodRuntimeManifest { param(`$RuntimeDirectory,`$ExpectedRuntimeId) [IO.File]::WriteAllText('$manifestCapture',([ordered]@{RuntimeDirectory=`$RuntimeDirectory;ExpectedRuntimeId=`$ExpectedRuntimeId}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false));[pscustomobject]@{Valid=`$true;Code='CCOD_RUNTIME_VALID'} }
Export-ModuleMember -Function Read-CcodActiveRuntime,Test-CcodRuntimeManifest
"@
        [IO.File]::WriteAllText((Join-Path $app 'src\persistence\modules\RuntimeManifest.psm1'),$runtimeModule,[Text.UTF8Encoding]::new($false))
        $capture=Join-Path $root 'submission.json';New-CcodFakeLifecycleRequestModule (Join-Path $runtime 'src\persistence\modules\LifecycleRequest.psm1') $capture
        $activationId='99999999-8888-7777-6666-555555555555'

        $output=@(& $promptPath -AppRoot $app -InstallRoot $install -Choice Restart -ActivationId $activationId -NoUi 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'accepted restart submission exits successfully'
        Assert-CcodEqual 0 $output.Count 'accepted prompt emits no lifecycle receipt to stdout'
        Assert-CcodTrue (Test-Path -LiteralPath $capture -PathType Leaf) 'restart creates exactly one durable submission capture'
        $submission=Get-Content -LiteralPath $capture -Raw|ConvertFrom-Json
        Assert-CcodEqual 'RestartAndRepair' $submission.Kind 'prompt submits RestartAndRepair'
        Assert-CcodEqual 'Installer' $submission.Origin 'prompt records installer origin'
        Assert-CcodEqual $runtimeId $submission.RuntimeId 'prompt binds active manifest runtime'
        Assert-CcodEqual 7 ([UInt64]$submission.RuntimeGeneration) 'prompt binds active generation'
        Assert-CcodTrue (-not(Test-Path -LiteralPath (Join-Path $root 'controller-called.txt'))) 'prompt never invokes the direct controller wrapper'
        $manifest=Get-Content -LiteralPath $manifestCapture -Raw|ConvertFrom-Json
        Assert-CcodEqual $runtimeId $manifest.ExpectedRuntimeId 'prompt validates the exact active runtime manifest'
        $records=@(Get-Content -LiteralPath (Join-Path $install 'logs\post-install-activation.log')|ForEach-Object{$_|ConvertFrom-Json})
        Assert-CcodEqual 1 $records.Count 'prompt appends one bounded restart record'
        Assert-CcodEqual $activationId $records[0].activationId 'restart log correlates activation id'
        Assert-CcodEqual 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' $records[0].submissionId 'restart log correlates submission id'
        Assert-CcodEqual '11111111-2222-3333-4444-555555555555' $records[0].transactionId 'restart log correlates transaction id'
        Assert-CcodEqual 'RESTART_SUBMITTED' $records[0].code 'restart log uses a stable public code'
        Assert-CcodTrue ($records[0].durationMilliseconds -is [long] -or $records[0].durationMilliseconds -is [int]) 'restart log records bounded duration'
    }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'restart prompt rejects and never echoes an untrusted accepted receipt' {
    # Production mutation caught: treating accepted=true as sufficient and serializing attacker-controlled receipt fields to stdout.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-prompt-invalid-receipt-'+[guid]::NewGuid().ToString('N'))
    try{
        $app=Join-Path $root 'app';$install=Join-Path $root 'install';$runtimeId='2.5.0-runtime';$runtime=Join-Path $install "runtime\$runtimeId"
        [IO.Directory]::CreateDirectory((Join-Path $app 'src\persistence\modules'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'src\persistence\modules'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'active.json'),'{}',[Text.UTF8Encoding]::new($false))
        $runtimeModule=@"
function Read-CcodActiveRuntime { param(`$InstallRoot) [pscustomobject][ordered]@{activeRuntime='$runtimeId';generation=[UInt64]7} }
function Test-CcodRuntimeManifest { param(`$RuntimeDirectory,`$ExpectedRuntimeId) [pscustomobject]@{Valid=`$true;Code='CCOD_RUNTIME_VALID'} }
Export-ModuleMember -Function Read-CcodActiveRuntime,Test-CcodRuntimeManifest
"@
        [IO.File]::WriteAllText((Join-Path $app 'src\persistence\modules\RuntimeManifest.psm1'),$runtimeModule,[Text.UTF8Encoding]::new($false))
        $malicious=[ordered]@{schemaVersion=1;submissionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';accepted=$true;transactionId='ATTACKER_STDOUT_MARKER';errorCode=$null;completedAtUtc='2030-02-03T04:05:06.0000000Z'}
        New-CcodFakeLifecycleReceiptModule (Join-Path $runtime 'src\persistence\modules\LifecycleRequest.psm1') $malicious
        $output=@(& $promptPath -AppRoot $app -InstallRoot $install -Choice Restart -ActivationId '99999999-8888-7777-6666-555555555555' -NoUi 2>&1)
        Assert-CcodEqual 1 $LASTEXITCODE 'untrusted accepted receipt exits nonzero'
        $text=$output-join"`n"
        Assert-CcodTrue ($text-cmatch'CCOD_RESTART_RECEIPT_INVALID') 'untrusted receipt returns the bounded stable code on stderr'
        Assert-CcodTrue ($text-cnotmatch'ATTACKER_STDOUT_MARKER') 'untrusted transaction data is never echoed'
        $record=(Get-Content -LiteralPath (Join-Path $install 'logs\post-install-activation.log')|Select-Object -Last 1)|ConvertFrom-Json
        Assert-CcodEqual 'CCOD_RESTART_RECEIPT_INVALID' $record.code 'invalid receipt support code remains durable'
        Assert-CcodEqual $null $record.submissionId 'invalid receipt does not persist an untrusted submission id'
        Assert-CcodEqual $null $record.transactionId 'invalid receipt does not persist an untrusted transaction id'
    }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'restart prompt Later performs no lifecycle or controller write' {
    # Production mutation caught: resolving runtime state, creating inbox/log files, or invoking a controller after the user chooses Later.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-prompt-later-'+[guid]::NewGuid().ToString('N'))
    try{
        $app=Join-Path $root 'app';$install=Join-Path $root 'install';$inbox=Join-Path $install 'state\lifecycle\inbox';$marker=Join-Path $root 'controller-called.txt'
        [IO.Directory]::CreateDirectory($app)|Out-Null;[IO.Directory]::CreateDirectory($inbox)|Out-Null
        [IO.File]::WriteAllText((Join-Path $app 'Start-CodexControlOtherDevices.ps1'),"[IO.File]::WriteAllText('$marker','called')",[Text.UTF8Encoding]::new($false))
        $output=@(& $promptPath -AppRoot $app -InstallRoot $install -Choice Later -ActivationId '99999999-8888-7777-6666-555555555555' -NoUi 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'Later exits successfully'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $inbox -File -Force).Count 'Later creates zero inbox files'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $marker)) 'Later makes zero controller calls'
        Assert-CcodTrue (-not(Test-Path -LiteralPath (Join-Path $install 'logs\post-install-activation.log'))) 'Later creates no restart log record'
    }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'restart prompt preserves submitter stderr and rejected stable support code' {
    # Production mutation caught: redirecting stderr to null, discarding a rejected receipt code, or returning zero after Supervisor rejection.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-prompt-rejected-'+[guid]::NewGuid().ToString('N'))
    try{
        $app=Join-Path $root 'app';$install=Join-Path $root 'install';$runtimeId='2.5.0-runtime';$runtime=Join-Path $install "runtime\$runtimeId"
        [IO.Directory]::CreateDirectory((Join-Path $app 'src\persistence\modules'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'src\persistence\modules'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'active.json'),'{"schemaVersion":2}',[Text.UTF8Encoding]::new($false))
        $runtimeModule=@"
function Read-CcodActiveRuntime { param(`$InstallRoot) [pscustomobject][ordered]@{activeRuntime='$runtimeId';generation=[UInt64]7} }
function Test-CcodRuntimeManifest { param(`$RuntimeDirectory,`$ExpectedRuntimeId) [pscustomobject]@{Valid=`$true;Code='CCOD_RUNTIME_VALID'} }
Export-ModuleMember -Function Read-CcodActiveRuntime,Test-CcodRuntimeManifest
"@
        [IO.File]::WriteAllText((Join-Path $app 'src\persistence\modules\RuntimeManifest.psm1'),$runtimeModule,[Text.UTF8Encoding]::new($false))
        $capture=Join-Path $root 'submission.txt'
        $requestModule=@"
function Submit-CcodLifecycleRequest {
    param(`$InstallRoot,`$Kind,`$Origin,`$RuntimeId,`$RuntimeGeneration,`$TimeoutMilliseconds)
    [IO.File]::AppendAllText('$capture','submitted'+[Environment]::NewLine,[Text.UTF8Encoding]::new(`$false))
    Write-Error 'CCOD_FAKE_SUBMIT_STDERR' -ErrorAction Continue
    [pscustomobject][ordered]@{schemaVersion=1;submissionId='bbbbbbbb-cccc-dddd-eeee-ffffffffffff';accepted=`$false;transactionId=`$null;errorCode='CCOD_LIFECYCLE_SUPERVISOR_BUSY';completedAtUtc='2030-02-03T04:05:06.0000000Z'}
}
Export-ModuleMember -Function Submit-CcodLifecycleRequest
"@
        [IO.File]::WriteAllText((Join-Path $runtime 'src\persistence\modules\LifecycleRequest.psm1'),$requestModule,[Text.UTF8Encoding]::new($false))
        $output=@(& $promptPath -AppRoot $app -InstallRoot $install -Choice Restart -ActivationId '99999999-8888-7777-6666-555555555555' -NoUi 2>&1)
        Assert-CcodEqual 1 $LASTEXITCODE 'rejected receipt exits nonzero'
        Assert-CcodEqual 1 @(Get-Content -LiteralPath $capture).Count 'rejected restart still submits exactly once'
        $text=$output-join"`n"
        Assert-CcodTrue ($text-cmatch'CCOD_FAKE_SUBMIT_STDERR') 'submitter stderr is retained'
        Assert-CcodTrue ($text-cmatch'CCOD_LIFECYCLE_SUPERVISOR_BUSY') 'rejected stable support code is retained'
        $record=(Get-Content -LiteralPath (Join-Path $install 'logs\post-install-activation.log')|Select-Object -Last 1)|ConvertFrom-Json
        Assert-CcodEqual 'CCOD_LIFECYCLE_SUPERVISOR_BUSY' $record.code 'rejected support code is durable'
        Assert-CcodEqual 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff' $record.submissionId 'rejected submission remains correlated'
        Assert-CcodEqual $null $record.transactionId 'rejected receipt has no fabricated transaction id'
    }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'public uninstall wrapper rejects retired direct options and delegates portable cleanup to an external verified finalizer' {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($uninstallPath,[ref]$tokens,[ref]$errors)
    Assert-CcodTrue (@($errors).Count -eq 0) 'Uninstall wrapper parses'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    Assert-CcodTrue ($commands -ccontains 'Start-Process') 'Uninstall wrapper delegates portable finalization to an external process'
    Assert-CcodTrue ($commands -ccontains 'Import-Module') 'Uninstall wrapper verifies the installed portable marker through its manifest-bound module'
    foreach($forbidden in @('Remove-Item','Move-Item','Copy-Item','Invoke-CcodUninstall')){Assert-CcodTrue ($commands -cnotcontains $forbidden) "Uninstall wrapper has no direct $forbidden path"}
    $source=Get-Content -LiteralPath $uninstallPath -Raw -Encoding UTF8
    foreach($required in @('portable-release.json','Assert-CcodPortableInstalledMarker','-Mode Prepare','PortableUninstallFinalizer.ps1')){
        Assert-CcodTrue ($source -cmatch [regex]::Escape($required)) "Uninstall wrapper requires $required for the portable finalization boundary"
    }
    foreach($argument in @(@{Name='KeepCurrentSpecialSession';Value=$true},@{Name='BackupDeviceKeyStore';Value=$true},@{Name='RemoveDeviceKeyStore';Value=$true})){
        $failure=$null
        $parameters=@{};$parameters[[string]$argument.Name]=$argument.Value
        try { & $uninstallPath @parameters } catch { $failure=$_ }
        Assert-CcodTrue ($null-ne$failure -and $failure.FullyQualifiedErrorId-like'CCOD_UNINSTALL_OPTION_REMOVED*') "retired uninstall option $($argument.Name) fails closed"
    }
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-wrapper-'+[guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $fixtureScript=Join-Path $root 'Uninstall-CodexControlOtherDevices.ps1'
        [IO.File]::Copy($uninstallPath,$fixtureScript,$true)
        [IO.File]::WriteAllText((Join-Path $root 'unins000.exe'),'placeholder',[Text.UTF8Encoding]::new($false))
        $receipt=& $fixtureScript -WhatIf
        Assert-CcodEqual 'WhatIf' $receipt.Outcome 'WhatIf does not launch the placeholder uninstaller'
        Assert-CcodEqual $true $receipt.KeptDeviceKeyStore 'WhatIf confirms the device-key store remains in place'
    } finally { if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force} }
}

Write-Host 'Manual wrapper self-tests passed.'
