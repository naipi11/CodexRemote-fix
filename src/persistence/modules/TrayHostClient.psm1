Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:CcodTrayHostAssemblyPath=$null

function Get-CcodTrayHostRuntimeRoot {
    $moduleRoot=Split-Path $PSCommandPath -Parent
    return [IO.Path]::GetFullPath((Split-Path (Split-Path (Split-Path $moduleRoot -Parent) -Parent) -Parent))
}

function Import-CcodTrayHostAssembly {
    $runtimeRoot=Get-CcodTrayHostRuntimeRoot
    $path=Join-Path $runtimeRoot 'bin\CodexRemote.TrayHost.exe'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'CCOD_TRAYHOST_ARTIFACT_MISSING'}
    $full=[IO.Path]::GetFullPath($path)
    if($script:CcodTrayHostAssemblyPath -cne $full){[Reflection.Assembly]::LoadFrom($full)|Out-Null;$script:CcodTrayHostAssemblyPath=$full}
}

function Convert-CcodTrayHostColor([string]$Value) {
    switch($Value){'Green'{return [TrayColor]::Green}'Yellow'{return [TrayColor]::Yellow}'Red'{return [TrayColor]::Red}default{return [TrayColor]::Gray}}
}
function Convert-CcodTrayHostState([string]$Value) {
    switch($Value){'Inspecting'{return [TrayState]::Inspecting}'Transitioning'{return [TrayState]::Transitioning}'Active'{return [TrayState]::Active}'ActivePaused'{return [TrayState]::ActivePaused}'RendererHandoff'{return [TrayState]::RendererHandoff}'Suppressed'{return [TrayState]::Suppressed}'Recovered'{return [TrayState]::Recovered}'Error'{return [TrayState]::Error}default{return [TrayState]::Waiting}}
}

function New-CcodTrayHostSnapshot {
    param($Presentation,$Catalog,[string]$LanguageMode,[string]$SystemCultureName,[UInt64]$Revision,[string]$RuntimeId)
    $flags=[PresentationFlags]::None
    $flagMap=@{
        SessionReadyVisible=[PresentationFlags]::SessionReadyVisible;ApplyNowVisible=[PresentationFlags]::ApplyNowVisible;ApplyNowEnabled=[PresentationFlags]::ApplyNowEnabled
        ManualRetryVisible=[PresentationFlags]::ManualRetryVisible;ManualRetryEnabled=[PresentationFlags]::ManualRetryEnabled;AutomationToggleEnabled=[PresentationFlags]::AutomationToggleEnabled
        AutomationChecked=[PresentationFlags]::AutomationChecked;CandidateOptInToggleEnabled=[PresentationFlags]::CandidateOptInToggleEnabled;CandidateOptInChecked=[PresentationFlags]::CandidateOptInChecked
        OpenLogsEnabled=[PresentationFlags]::OpenLogsEnabled;UninstallEnabled=[PresentationFlags]::UninstallEnabled;Busy=[PresentationFlags]::Busy
    }
    foreach($pair in @(
        @('SessionReadyVisible','SessionReadyVisible'),@('ApplyNowVisible','ApplyNowVisible'),@('ApplyNowEnabled','ApplyNowEnabled'),
        @('ManualRetryVisible','ManualRetryVisible'),@('ManualRetryEnabled','ManualRetryEnabled'),@('AutomationToggleEnabled','AutomationToggleEnabled'),
        @('AutomationChecked','AutomationChecked'),@('CandidateOptInToggleEnabled','CandidateOptInToggleEnabled'),@('CandidateOptInChecked','CandidateOptInChecked'),
        @('OpenLogsEnabled','OpenLogsEnabled'),@('UninstallEnabled','UninstallEnabled'),@('Busy','Busy'))){
        if($Presentation.($pair[0]) -is [bool] -and $Presentation.($pair[0])){$flags=[PresentationFlags]([int]$flags -bor [int]$flagMap[$pair[1]])}
    }
    $stateKey=[string]$Presentation.StateKey
    $systemLanguage=if([string]$SystemCultureName -cmatch '^zh(?:-|$)'){$Catalog.Strings.'Menu.Chinese'}else{$Catalog.Strings.'Menu.English'}
    $follow=Get-CcodUiString -Catalog $Catalog -Key 'Menu.FollowSystem' -Arguments @($systemLanguage)
    $tooltipKey='Tooltip.'+$stateKey
    $tooltip=if($null -ne $Catalog.Strings.PSObject.Properties[$tooltipKey]){$Catalog.Strings.$tooltipKey}else{$Catalog.Strings.'Tooltip.Waiting'}
    $projectVersion='unknown'
    if($RuntimeId -is [string] -and $RuntimeId -cmatch '^(?<version>\d+\.\d+\.\d+)-'){$projectVersion=$Matches['version']}
    $aboutVersion=Get-CcodUiString -Catalog $Catalog -Key 'Menu.AboutVersion' -Arguments @($projectVersion)
    $strings=[string[]]@(
        $Catalog.Strings.'Tray.Title',
        $Catalog.Strings.('Status.'+$stateKey),
        $Catalog.Strings.'Menu.SessionReady',
        $Catalog.Strings.'Menu.ApplyNow',
        $Catalog.Strings.'Menu.ManualRetry',
        $Catalog.Strings.'Menu.Automation',
        $Catalog.Strings.'Menu.CandidateOptIn',
        $Catalog.Strings.'Menu.Language',
        $follow,
        $Catalog.Strings.'Menu.Chinese',
        $Catalog.Strings.'Menu.English',
        $Catalog.Strings.'Menu.OpenLogs',
        $Catalog.Strings.'Menu.About',
        $Catalog.Strings.'Menu.Uninstall',
        $Catalog.Strings.'Error.UninstallStart',
        $Catalog.Strings.'Menu.Uninstall',
        $tooltip,
        $Catalog.Strings.'Dialog.UninstallTitle',
        $Catalog.Strings.'Dialog.UninstallMessage',
        $aboutVersion
    )
    $mode=if($LanguageMode -ceq 'zh-CN'){[LanguageMode]::Chinese}elseif($LanguageMode -ceq 'en-US'){[LanguageMode]::English}else{[LanguageMode]::System}
    return [PresentationSnapshot]::new($Revision,(Convert-CcodTrayHostColor $Presentation.Color),(Convert-CcodTrayHostState $stateKey),$mode,$flags,$strings)
}

function New-CcodTrayHostContext {
    param($CommandQueue,$OnTick,$Catalog,[string]$LanguageMode,[string]$SystemCultureName)
    Import-CcodTrayHostAssembly
    $runtimeRoot=Get-CcodTrayHostRuntimeRoot;$runtimeId=Split-Path $runtimeRoot -Leaf;$exe=Join-Path $runtimeRoot 'bin\CodexRemote.TrayHost.exe'
    $initialPresentation=[pscustomobject][ordered]@{Color='Gray';StateKey='Waiting';SessionReadyVisible=$false;ApplyNowVisible=$false;ApplyNowEnabled=$false;ManualRetryVisible=$false;ManualRetryEnabled=$false;AutomationToggleEnabled=$true;AutomationChecked=$false;CandidateOptInToggleEnabled=$true;CandidateOptInChecked=$false;OpenLogsEnabled=$true;UninstallEnabled=$true;Busy=$false}
    $initial=New-CcodTrayHostSnapshot $initialPresentation $Catalog $LanguageMode $SystemCultureName ([UInt64]1) $runtimeId
    $process=[Diagnostics.Process]::GetCurrentProcess()
    try{
        $options=[TrayHostStartOptions]::new();$options.ExePath=$exe;$options.RuntimeId=$runtimeId;$options.ParentPid=$process.Id;$options.ParentCreationFileTimeUtc=$process.StartTime.ToFileTimeUtc();$options.InitialPresentation=$initial
        $client=[TrayHostParentClient]::Start($options)
    }finally{$process.Dispose()}
    return [pscustomobject][ordered]@{Client=$client;CommandQueue=$CommandQueue;OnTick=$OnTick;Catalog=$Catalog;LanguageMode=$LanguageMode;SystemCultureName=$SystemCultureName;RuntimeId=$runtimeId;CurrentRevision=[UInt64]1;LastAcknowledgedRevision=[UInt64]1;MenuOpen=$false;Exited=$false;LastError=$null;ApplicationContext=[pscustomobject]@{}}
}

function Set-CcodTrayHostPresentation {
    param($Context,$Presentation,$Catalog,[string]$LanguageMode,[string]$SystemCultureName,[switch]$WaitForAcknowledgement)
    if($null -eq $Context -or $null -eq $Context.Client){throw 'CCOD_TRAYHOST_CONTEXT_INVALID'}
    $revision=[UInt64]([UInt64]$Context.CurrentRevision + [UInt64]1)
    $snapshot=New-CcodTrayHostSnapshot $Presentation $Catalog $LanguageMode $SystemCultureName $revision $Context.RuntimeId
    if(-not $Context.Client.TryPublish($snapshot)){throw 'CCOD_TRAYHOST_PRESENTATION_FAILED'}
    $Context.Catalog=$Catalog;$Context.LanguageMode=$LanguageMode;$Context.SystemCultureName=$SystemCultureName;$Context.CurrentRevision=$revision
    if($WaitForAcknowledgement){
        $deadline=[DateTime]::UtcNow.AddMilliseconds(1250)
        while([UInt64]$Context.LastAcknowledgedRevision -lt $revision -and [DateTime]::UtcNow -lt $deadline){
            Receive-CcodTrayHostEvents $Context
            if([UInt64]$Context.LastAcknowledgedRevision -ge $revision){break}
            [void]$Context.Client.WaitForActivity([TimeSpan]::FromMilliseconds(25))
        }
        if([UInt64]$Context.LastAcknowledgedRevision -lt $revision){throw 'CCOD_TRAYHOST_PRESENTATION_ACK_TIMEOUT'}
    }
}

function Receive-CcodTrayHostEvents {
    param($Context)
    while($true){
        $event=$null
        if(-not $Context.Client.TryDequeueEvent([ref]$event)){break}
        if($null -eq $event){continue}
        switch($event.Kind.ToString()){
            'PresentationAck' {if($event.Revision -is [UInt64] -or $event.Revision -is [long] -or $event.Revision -is [int]){if([UInt64]$event.Revision -gt [UInt64]$Context.LastAcknowledgedRevision){$Context.LastAcknowledgedRevision=[UInt64]$event.Revision}}}
            'Action' {
                $command=switch($event.Command){CheckAndRepair{'CheckAndRepair'}SetLanguageSystem{'SetLanguageSystem'}SetLanguageChinese{'SetLanguageChinese'}SetLanguageEnglish{'SetLanguageEnglish'}OpenLogs{'OpenLogs'}ShowAbout{'ShowAbout'}Exit{'Exit'}default{$null}}
                if($null-eq$command-or$event.ActionId-eq[guid]::Empty-or$event.Revision-isnot[UInt64]-and$event.Revision-isnot[long]-and$event.Revision-isnot[int]){continue}
                $queueValue=[pscustomobject][ordered]@{ActionId=$event.ActionId;Command=$command;Revision=[UInt64]$event.Revision}
                [void]$Context.CommandQueue.Enqueue($queueValue)
            }
            'Exited' {$Context.Exited=$true}
            'Fault' {$Context.LastError=$event.ErrorCode;$Context.Exited=$true}
        }
    }
}

function Send-CcodTrayHostActionResult {
    param($Context,[guid]$ActionId,[UInt64]$Revision,[ValidateSet('Accepted','Completed','Rejected','Failed')][string]$Status,[AllowNull()][string]$ErrorCode,[AllowNull()][string]$TransactionId)
    if($null-eq$Context-or$null-eq$Context.Client-or$ActionId-eq[guid]::Empty-or$Revision-eq0){throw 'CCOD_TRAY_ACTION_RESULT_INVALID'}
    $success=$Status-in@('Accepted','Completed')
    if($success-and-not[string]::IsNullOrWhiteSpace($ErrorCode)){throw 'CCOD_TRAY_ACTION_RESULT_INVALID'}
    if(-not$success-and($ErrorCode-isnot[string]-or$ErrorCode-cnotmatch'^CCOD_[A-Z0-9_]{1,91}$')){throw 'CCOD_TRAY_ACTION_RESULT_INVALID'}
    $transactionGuid=$null
    if(-not[string]::IsNullOrWhiteSpace($TransactionId)){
        $parsed=[guid]::Empty
        if(-not[guid]::TryParseExact($TransactionId,'D',[ref]$parsed)){throw 'CCOD_TRAY_ACTION_RESULT_INVALID'}
        $transactionGuid=$parsed
    }
    try{$result=[TrayActionResult]::new($ActionId,$Revision,[TrayActionResultStatus]::$Status,$ErrorCode,$transactionGuid)}catch{throw 'CCOD_TRAY_ACTION_RESULT_INVALID'}
    if(-not$Context.Client.TryAcknowledgeAction($result)){throw 'CCOD_TRAY_ACTION_ACK_REJECTED'}
    return $true
}

function Invoke-CcodTrayHostRunLoop {
    param($Context)
    while(-not $Context.Exited){
        Receive-CcodTrayHostEvents $Context
        if($Context.Exited){break}
        & $Context.OnTick $false
        Receive-CcodTrayHostEvents $Context
        if($Context.Exited){break}
        [void]$Context.Client.WaitForActivity([TimeSpan]::FromMilliseconds(250))
    }
}

function Request-CcodTrayHostExit { param($Context) if($null -ne $Context -and $null -ne $Context.Client){[void]$Context.Client.BeginShutdown([ShutdownReason]::SupervisorExit,[UInt64]$Context.CurrentRevision);$Context.Exited=$true} }
function Close-CcodTrayHostContext { param($Context) if($null -ne $Context -and $null -ne $Context.Client){$Context.Client.Dispose();$Context.Client=$null};if($null -ne $Context){$Context.Exited=$true};return [pscustomobject][ordered]@{Closed=$true;ErrorCode=$null} }
function Show-CcodTrayHostError { param($Context,$Catalog,$Key) if($null -ne $Context){$Context.LastError=$Key} }
function End-CcodTrayHostMenu { param($Context) return $true }

Export-ModuleMember -Function New-CcodTrayHostContext,Set-CcodTrayHostPresentation,Receive-CcodTrayHostEvents,Send-CcodTrayHostActionResult,Invoke-CcodTrayHostRunLoop,Request-CcodTrayHostExit,Close-CcodTrayHostContext,Show-CcodTrayHostError,End-CcodTrayHostMenu
