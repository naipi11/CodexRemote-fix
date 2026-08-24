$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\TrayUi.psm1'
$localizationPath=Join-Path $repositoryRoot 'src\persistence\modules\UiLocalization.psm1'
$resourcesRoot=Join-Path $repositoryRoot 'src\persistence\resources'
if(-not [IO.File]::Exists($modulePath)){
    throw 'MISSING_TRAY_UI_MODULE: src\persistence\modules\TrayUi.psm1'
}
Import-Module $localizationPath -Force
Import-Module $modulePath -Force
$script:TestEnglishCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode en-US -SystemCultureName en-US
$script:TestChineseCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode zh-CN -SystemCultureName zh-CN
$script:TestSystemCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode System -SystemCultureName zh-CN

function New-CcodTestTrayContext {
    param($CommandQueue,[scriptblock]$OnTick,$Adapters,$Catalog=$script:TestEnglishCatalog,[string]$LanguageMode='en-US',[string]$SystemCultureName='en-US')
    TrayUi\New-CcodTrayContext -CommandQueue $CommandQueue -OnTick $OnTick -Catalog $Catalog -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName -Adapters $Adapters
}

function Set-CcodTestTrayPresentation {
    param($Context,$Presentation,$Catalog=$script:TestEnglishCatalog,[string]$LanguageMode='en-US',[string]$SystemCultureName='en-US')
    TrayUi\Set-CcodTrayPresentation -Context $Context -Presentation $Presentation -Catalog $Catalog -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName
}
Set-Alias -Name New-CcodTrayContext -Value New-CcodTestTrayContext -Scope Script
Set-Alias -Name Set-CcodTrayPresentation -Value Set-CcodTestTrayPresentation -Scope Script

function New-CcodTrayTestQueue {
    Write-Output -NoEnumerate ([Collections.Generic.Queue[object]]::new())
}

function New-CcodTrayFakeAdapters {
    $state=[pscustomobject]@{
        Calls=[Collections.Generic.List[string]]::new()
        Objects=[Collections.Generic.List[object]]::new()
        Bitmaps=[Collections.Generic.List[object]]::new()
        IconClones=[Collections.Generic.List[object]]::new()
        TitleBitmaps=[Collections.Generic.List[object]]::new()
        BoldFonts=[Collections.Generic.List[object]]::new()
        Dialogs=[Collections.Generic.List[object]]::new()
        MenuEndCount=0
        HiconSeed=1000
        ThreadId=37
        Apartment='STA'
        Now=[DateTimeOffset]::new(2030,2,3,4,5,6,[TimeSpan]::Zero)
        SourceSeed=0
        TraceCalls=0
        IntrinsicCalls=0
        TraceHandler=$null
        IntrinsicHandler=$null
        TraceClass=$null
        IntrinsicQuery=$null
        TraceReceipt=$null
        IntrinsicReceipt=$null
        ActiveSources=@{}
    }
    $adapters=@{
        GetUtcNow={ $state.Calls.Add('Clock:GetUtcNow'); $state.Now }.GetNewClosure()
        GetQueueCount={ param($Queue) [int]$Queue.Count }
        TryEnqueue={ param($Queue,$Value) $Queue.Enqueue($Value); $true }
        TryDequeue={ param($Queue) if($Queue.Count -eq 0){[pscustomobject]@{Succeeded=$false;Value=$null}}else{[pscustomobject]@{Succeeded=$true;Value=$Queue.Dequeue()}} }
        GetManagedThreadId={ [int]$state.ThreadId }.GetNewClosure()
        GetApartmentState={ [string]$state.Apartment }.GetNewClosure()
        CreateUiObject={
            param($Kind,$Name)
            $state.Calls.Add("Create:$Kind`:$Name")
            $object=[pscustomobject]@{
                Kind=$Kind;Name=$Name;Properties=[ordered]@{IsDisposed=$false;Font=[pscustomobject]@{Bold=$false}};Events=[ordered]@{}
                Children=[Collections.Generic.List[object]]::new();Disposed=$false;DisposeCount=0
            }
            $state.Objects.Add($object)
            $object
        }.GetNewClosure()
        SetUiProperty={param($Object,$Name,$Value)$state.Calls.Add("Set:$($Object.Name):$Name");$Object.Properties[$Name]=$Value}.GetNewClosure()
        GetUiProperty={param($Object,$Name)$Object.Properties[$Name]}
        SetUiVisible={param($Object,$Visible)$state.Calls.Add("Visible:$($Object.Name):$Visible");$Object.Properties['Visible']=[bool]$Visible}.GetNewClosure()
        StartUiTimer={param($Timer)$state.Calls.Add("TimerStart:$($Timer.Name)");$Timer.Properties['Started']=$true}.GetNewClosure()
        StopUiTimer={param($Timer)$state.Calls.Add("TimerStop:$($Timer.Name)");$Timer.Properties['Started']=$false}.GetNewClosure()
        AttachUiCallback={
            param($Object,$EventName,$Callback)
            $state.Calls.Add("Attach:$($Object.Name):$EventName")
            $Object.Events[$EventName]=$Callback
            [pscustomobject][ordered]@{Target=$Object;EventName=$EventName;Handler=$Callback}
        }.GetNewClosure()
        DetachUiCallback={param($Attachment)$state.Calls.Add("Detach:$($Attachment.Target.Name):$($Attachment.EventName)");$Attachment.Target.Events.Remove($Attachment.EventName)}.GetNewClosure()
        AddUiChild={param($Parent,$Child)$state.Calls.Add("Add:$($Parent.Name):$($Child.Name)");$Parent.Children.Add($Child)}.GetNewClosure()
        DisposeUiObject={
            param($Object)
            $state.Calls.Add("DisposeUi:$($Object.Name)");$Object.Disposed=$true;$Object.Properties['IsDisposed']=$true;$Object.DisposeCount++
        }.GetNewClosure()
        ExitUiContext={param($Context)$state.Calls.Add("ExitUi:$($Context.Name)")}.GetNewClosure()
        CreateBitmap={
            param($Color,$Size)
            $state.Calls.Add("Bitmap:$Color`:$Size")
            $bitmap=[pscustomobject]@{Color=$Color;Size=[int]$Size;Disposed=$false;DisposeCount=0}
            $state.Bitmaps.Add($bitmap);$bitmap
        }.GetNewClosure()
        DrawBridgeIcon={param($Bitmap,$Color,$Size)$state.Calls.Add("Draw:$Color`:$Size")}.GetNewClosure()
        GetHicon={param($Bitmap)$state.HiconSeed++;$state.Calls.Add("GetHicon:$($Bitmap.Color):$($Bitmap.Size)");[IntPtr]$state.HiconSeed}.GetNewClosure()
        CloneIcon={
            param($Hicon,$Color,$Size)
            $state.Calls.Add("Clone:$Color`:$Size");$icon=[pscustomobject]@{Color=$Color;Size=[int]$Size;Disposed=$false;DisposeCount=0}
            $state.IconClones.Add($icon);$icon
        }.GetNewClosure()
        ShowErrorDialog={param($Title,$Message)$state.Dialogs.Add([pscustomobject][ordered]@{Title=$Title;Message=$Message})}.GetNewClosure()
        ConfirmUninstall={param($Title,$Message)$true}
        EndMenu={$state.MenuEndCount++;$state.Calls.Add('Menu:End')}.GetNewClosure()
        DestroyIcon={param($Hicon)$state.Calls.Add("DestroyIcon:$([long]$Hicon)")}.GetNewClosure()
        DisposeIconResource={param($Resource)if($Resource.PSObject.Properties['Kind']){$state.Calls.Add("DisposeResource:$($Resource.Kind):$($Resource.Name)")}else{$state.Calls.Add("DisposeIcon:$($Resource.Color):$($Resource.Size)")};$Resource.Disposed=$true;$Resource.DisposeCount++}.GetNewClosure()
        NewSourceIdentifier={$state.SourceSeed++;'ccod-process-'+('{0:x32}' -f $state.SourceSeed)}.GetNewClosure()
        RegisterTrace={
            param($SourceIdentifier,$ClassName,$Callback)
            $state.TraceCalls++;$state.TraceClass=$ClassName;$state.TraceHandler=$Callback
            $resource=[pscustomobject]@{Kind='TraceResource';Disposed=$false}
            $state.TraceReceipt=[pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=[int](100+$state.TraceCalls);Resource=$resource}
            $state.ActiveSources[$SourceIdentifier]=$resource
            $state.TraceReceipt
        }.GetNewClosure()
        RegisterIntrinsic={
            param($SourceIdentifier,$Query,$Callback)
            $state.IntrinsicCalls++;$state.IntrinsicQuery=$Query;$state.IntrinsicHandler=$Callback
            $resource=[pscustomobject]@{Kind='IntrinsicResource';Disposed=$false}
            $state.IntrinsicReceipt=[pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=[int](200+$state.IntrinsicCalls);Resource=$resource}
            $state.ActiveSources[$SourceIdentifier]=$resource
            $state.IntrinsicReceipt
        }.GetNewClosure()
        CleanupWatcherAttempt={param($SourceIdentifier)$state.Calls.Add("WatcherAttemptCleanup:$SourceIdentifier");[void]$state.ActiveSources.Remove($SourceIdentifier)}.GetNewClosure()
        DetachWatcherCallback={param($Receipt)$state.Calls.Add("WatcherDetach:$($Receipt.SourceIdentifier)")}.GetNewClosure()
        UnregisterWatcher={param($SourceIdentifier)$state.Calls.Add("WatcherUnregister:$SourceIdentifier");[void]$state.ActiveSources.Remove($SourceIdentifier)}.GetNewClosure()
        RemoveWatcherJob={param($JobId)$state.Calls.Add("WatcherRemoveJob:$JobId")}.GetNewClosure()
        DisposeWatcherResource={param($Resource)$state.Calls.Add("WatcherDispose:$($Resource.Kind)");$Resource.Disposed=$true}.GetNewClosure()
    }
    [pscustomobject]@{State=$state;Adapters=$adapters}
}

function New-CcodValidPresentation {
    [pscustomobject][ordered]@{
        Color='Green';StateKey='Active';SessionReadyVisible=$true;ApplyNowVisible=$false;ApplyNowEnabled=$false;ManualRetryVisible=$false;ManualRetryEnabled=$false
        AutomationToggleEnabled=$true;AutomationChecked=$true
        CandidateOptInToggleEnabled=$true;CandidateOptInChecked=$false;OpenLogsEnabled=$true;UninstallEnabled=$true;Busy=$false
    }
}

function Test-CcodOpaquePixels {
    param([Drawing.Bitmap]$Bitmap,[ValidateSet('base')][string]$Region)
    $samples=if($Bitmap.Width -eq 16){
        [pscustomobject]@{Outside=@(@(1,1),@(14,1),@(1,14));Inside=@(@(2,2),@(13,2),@(2,13))}
    }elseif($Bitmap.Width -eq 32){
        [pscustomobject]@{Outside=@(@(2,2),@(29,2),@(2,29));Inside=@(@(4,4),@(27,4),@(4,27))}
    }else{return $false}
    foreach($point in $samples.Outside){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        if($pixel.A -ge 128 -or ($pixel.R -eq 32 -and $pixel.G -eq 37 -and $pixel.B -eq 45)){return $false}
    }
    foreach($point in $samples.Inside){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        if($pixel.A -ne 255 -or $pixel.R -ne 32 -or $pixel.G -ne 37 -or $pixel.B -ne 45){return $false}
    }
    return $true
}

function Test-CcodLightPixels {
    param([Drawing.Bitmap]$Bitmap,[ValidateSet('links')][string]$Region)
    $regions=if($Bitmap.Width -eq 16){
        @(@(3,5,6,11),@(11,13,4,9))
    }elseif($Bitmap.Width -eq 32){
        @(@(6,10,12,22),@(22,26,8,18))
    }else{return $false}
    foreach($bounds in $regions){
        $found=$false
        for($y=$bounds[2];$y -le $bounds[3] -and -not $found;$y++){
            for($x=$bounds[0];$x -le $bounds[1];$x++){
                $pixel=$Bitmap.GetPixel($x,$y)
                if($pixel.A -ge 220 -and $pixel.R -ge 230 -and $pixel.G -ge 230 -and $pixel.B -ge 230){$found=$true;break}
            }
        }
        if(-not $found){return $false}
    }
    return $true
}

function Test-CcodStatusPixels {
    param([Drawing.Bitmap]$Bitmap,[ValidateSet('dot')][string]$Region,[ValidateSet('Gray','Green','Yellow','Red')][string]$Color)
    $expected=@{
        Gray=@(138,144,153);Green=@(41,179,111);Yellow=@(227,160,8);Red=@(217,74,74)
    }[$Color]
    $samples=if($Bitmap.Width -eq 16){
        [pscustomobject]@{
            Bounds=@(10,15,10,15);Center=@(12,12)
            Outline=@(@(12,11),@(11,12),@(14,12),@(12,14))
            Outside=@(@(14,10),@(10,14),@(15,12),@(12,15))
        }
    }elseif($Bitmap.Width -eq 32){
        [pscustomobject]@{
            Bounds=@(21,30,21,30);Center=@(25,25)
            Outline=@(@(25,22),@(22,25),@(28,25),@(25,28))
            Outside=@(@(25,20),@(20,25),@(30,25),@(25,30))
        }
    }else{return $false}
    $fillCount=0
    for($y=$samples.Bounds[2];$y -le $samples.Bounds[3];$y++){
        for($x=$samples.Bounds[0];$x -le $samples.Bounds[1];$x++){
            $pixel=$Bitmap.GetPixel($x,$y)
            if($pixel.A -eq 255 -and $pixel.R -eq $expected[0] -and $pixel.G -eq $expected[1] -and $pixel.B -eq $expected[2]){$fillCount++}
        }
    }
    $expectedFillCount=if($Bitmap.Width -eq 16){1}else{21}
    if($fillCount -ne $expectedFillCount){return $false}
    $center=$Bitmap.GetPixel([int]$samples.Center[0],[int]$samples.Center[1])
    if($center.A -ne 255 -or $center.R -ne $expected[0] -or $center.G -ne $expected[1] -or $center.B -ne $expected[2]){return $false}
    foreach($point in $samples.Outline){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        $whiteDelta=($pixel.R-$expected[0])+($pixel.G-$expected[1])+($pixel.B-$expected[2])
        if($pixel.A -ne 255 -or $pixel.R -le $expected[0] -or $pixel.G -le $expected[1] -or $pixel.B -le $expected[2] -or $whiteDelta -lt 150){return $false}
    }
    foreach($point in $samples.Outside){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        $whiteDelta=($pixel.R-$expected[0])+($pixel.G-$expected[1])+($pixel.B-$expected[2])
        if($pixel.R -gt $expected[0] -and $pixel.G -gt $expected[1] -and $pixel.B -gt $expected[2] -and $whiteDelta -ge 150){return $false}
        if($pixel.A -ne 0 -and ($pixel.R -gt 128 -or $pixel.G -gt 128 -or $pixel.B -gt 128)){return $false}
    }
    return $true
}

function Test-CcodTransparentCorners {
    param([Drawing.Bitmap]$Bitmap)
    foreach($point in @(@(0,0),@(($Bitmap.Width-1),0),@(0,($Bitmap.Height-1)),@(($Bitmap.Width-1),($Bitmap.Height-1)))){
        if($Bitmap.GetPixel([int]$point[0],[int]$point[1]).A -ne 0){return $false}
    }
    return $true
}

$results=[Collections.Generic.List[object]]::new()

$results.Add((Invoke-CcodTest 'exports exactly the six frozen TrayUi functions' {
    $expected='Close-CcodTrayContext,New-CcodTrayContext,Set-CcodTrayPresentation,Show-CcodTrayError,Start-CcodProcessWatcher,Stop-CcodProcessWatcher'
    $actual=((Get-Command -Module TrayUi -CommandType Function).Name|Sort-Object)-join ','
    Assert-CcodEqual $expected $actual 'public export surface remains exact'
}))

$results.Add((Invoke-CcodTest 'cold Windows PowerShell STA binds one persistent ContextMenu and supports two Popup Collapse lifecycles without MouseUp dispatch' {
    $escapedModulePath=$modulePath.Replace("'","''")
    $escapedLocalizationPath=$localizationPath.Replace("'","''")
    $escapedResourcesRoot=$resourcesRoot.Replace("'","''")
    $probe=@"
`$ErrorActionPreference='Stop'
Import-Module '$escapedLocalizationPath' -Force
Import-Module '$escapedModulePath' -Force
`$catalog=Get-CcodUiCatalog -ResourcesRoot '$escapedResourcesRoot' -LanguageMode en-US -SystemCultureName en-US
`$presentation=[pscustomobject][ordered]@{
    Color='Green';StateKey='Active';SessionReadyVisible=`$true;ApplyNowVisible=`$false;ApplyNowEnabled=`$false;ManualRetryVisible=`$false;ManualRetryEnabled=`$false
    AutomationToggleEnabled=`$true;AutomationChecked=`$true;CandidateOptInToggleEnabled=`$true;CandidateOptInChecked=`$false;OpenLogsEnabled=`$true;UninstallEnabled=`$true;Busy=`$false
}
`$context=`$null
try {
    `$context=New-CcodTrayContext -CommandQueue ([Collections.Generic.Queue[object]]::new()) -OnTick {} -Catalog `$catalog -LanguageMode en-US -SystemCultureName en-US
    Set-CcodTrayPresentation -Context `$context -Presentation `$presentation -Catalog `$catalog -LanguageMode en-US -SystemCultureName en-US
    `$menu=`$context.Menu
    if (`$null -eq `$menu -or `$menu.GetType().FullName -ne 'System.Windows.Forms.ContextMenu') { throw 'ContextMenu was not retained' }
    if (`$context.NotifyIcon.ContextMenu -ne `$menu) { throw 'NotifyIcon is not bound to ContextMenu' }
    if (@(`$context.Callbacks | Where-Object { `$_.EventName -eq 'MouseUp' }).Count -ne 0) { throw 'MouseUp callback is not allowed' }
    `$counts=[pscustomobject]@{Popup=0;Collapse=0}
    `$popupHandler=[EventHandler]{ param(`$sender,`$eventArgs) `$counts.Popup=`$counts.Popup+1 }.GetNewClosure()
    `$collapseHandler=[EventHandler]{ param(`$sender,`$eventArgs) `$counts.Collapse=`$counts.Collapse+1 }.GetNewClosure()
    `$menu.add_Popup(`$popupHandler);`$menu.add_Collapse(`$collapseHandler)
    `$flags=[Reflection.BindingFlags]'Instance,NonPublic'
    `$onPopup=`$menu.GetType().GetMethod('OnPopup',`$flags)
    `$onCollapse=`$menu.GetType().GetMethod('OnCollapse',`$flags)
    if (`$null -eq `$onPopup -or `$null -eq `$onCollapse) { throw 'ContextMenu lifecycle methods unavailable' }
    foreach(`$n in 1..2){
        [void]`$onPopup.Invoke(`$menu,@([EventArgs]::Empty))
        if (-not `$context.MenuOpen) { throw 'Popup did not open the context state' }
        [void]`$onCollapse.Invoke(`$menu,@([EventArgs]::Empty))
        if (`$context.MenuOpen) { throw 'Collapse did not close the context state' }
    }
    [pscustomobject]@{Type=`$menu.GetType().FullName;Popup=`$counts.Popup;Collapse=`$counts.Collapse;Callbacks=@(`$context.Callbacks|ForEach-Object {`$_.EventName})}|ConvertTo-Json -Compress
} finally {
    if (`$null -ne `$context) { Close-CcodTrayContext -Context `$context | Out-Null }
}
"@
    $output=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -Command $probe 2>&1)
    Assert-CcodEqual 0 $LASTEXITCODE 'cold ContextMenu STA probe exits cleanly'
    Assert-CcodEqual 1 $output.Count 'cold ContextMenu STA probe emits one JSON receipt'
    $receipt=[string]$output[0]|ConvertFrom-Json
    Assert-CcodEqual 'System.Windows.Forms.ContextMenu' $receipt.Type 'NotifyIcon uses the legacy native ContextMenu owner'
    Assert-CcodEqual 2 ([int]$receipt.Popup) 'two Popup events are delivered'
    Assert-CcodEqual 2 ([int]$receipt.Collapse) 'two Collapse events are delivered'
    Assert-CcodTrue (@($receipt.Callbacks) -notcontains 'MouseUp') 'framework automatic menu path has no MouseUp callback'
}))

$results.Add((Invoke-CcodTest 'prebuilds one bilingual ContextMenu graph, defers an open-menu presentation, and queues only the clicked command' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
        Assert-CcodEqual 'ContextMenu' $context.Menu.Kind 'one persistent legacy ContextMenu is constructed'
        Assert-CcodTrue ([object]::ReferenceEquals($context.Menu,$context.NotifyIcon.Properties.ContextMenu)) 'NotifyIcon is bound before it is visible'
        Assert-CcodEqual 'Title,Status,SessionReady,ApplyNow,ManualRetry,Automation,CandidateOptIn,Language,OpenLogs,Uninstall' (@($context.Items.Keys)-join ',') 'complete top-level menu graph is prebuilt in system order'
        Assert-CcodEqual 'System,Chinese,English' (@($context.LanguageItems.Keys)-join ',') 'complete language submenu is prebuilt'
        Assert-CcodEqual 'Popup,Collapse' (@($context.Callbacks|Where-Object {$_.EventName -in @('Popup','Collapse')}|ForEach-Object {$_.EventName}) -join ',') 'only ContextMenu lifecycle callbacks are attached to the menu'
        Assert-CcodTrue (@($context.Callbacks|Where-Object {$_.EventName -eq 'MouseUp'}).Count -eq 0) 'automatic tray menu path never attaches MouseUp'

        $active=New-CcodValidPresentation
        Set-CcodTrayPresentation -Context $context -Presentation $active
        Assert-CcodEqual 'CodexRemote-fix' $context.Items.Title.Properties.Text 'legacy diagnostic tray renders the current product title'
        Assert-CcodEqual 'Connection: Connected' $context.Items.Status.Properties.Text 'legacy diagnostic tray maps current connected evidence'
        & $context.Menu.Events.Popup $context.Menu $null
        Assert-CcodEqual $true $context.MenuOpen 'Popup begins the menu-open window'
        Set-CcodTrayPresentation -Context $context -Presentation $active -Catalog $script:TestSystemCatalog -LanguageMode System -SystemCultureName zh-CN
        Assert-CcodEqual 'CodexRemote-fix' $context.Items.Title.Properties.Text 'open menu keeps its current presentation until Collapse'
        Assert-CcodTrue ($null -ne $context.PendingRender) 'open menu coalesces the next render'
        & $context.Menu.Events.Collapse $context.Menu $null
        $zhTitle='CodexRemote-fix'
        Assert-CcodEqual $false $context.MenuOpen 'Collapse clears menu-open state'
        Assert-CcodEqual $zhTitle $context.Items.Title.Properties.Text 'Collapse flushes the newest bilingual render in place'
        Assert-CcodEqual $null $context.PendingRender 'Collapse clears the rendered pending snapshot'

        & $context.Items.OpenLogs.Events.Click $context.Items.OpenLogs $null
        Assert-CcodEqual 1 $queue.Count 'enabled menu item click queues one command'
        Assert-CcodEqual 'OpenLogs' $queue.Dequeue().Kind 'click queues its exact command without a MouseUp dispatcher'
    }finally{if($null -ne $context){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'shutdown ends an open ContextMenu then unbinds it before disposing retained tray resources' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        & $context.Menu.Events.Popup $context.Menu $null
        $receipt=Close-CcodTrayContext -Context $context
        Assert-CcodEqual $true $receipt.Closed 'close succeeds while ContextMenu is open'
        Assert-CcodEqual 1 $fake.State.MenuEndCount 'open ContextMenu is explicitly ended for shutdown'
        $endIndex=$fake.State.Calls.IndexOf('Menu:End')
        $unbindIndex=$fake.State.Calls.LastIndexOf('Set:TrayNotifyIcon:ContextMenu')
        $notifyDisposeIndex=$fake.State.Calls.IndexOf('DisposeUi:TrayNotifyIcon')
        $menuDisposeIndex=$fake.State.Calls.IndexOf('DisposeUi:TrayContextMenu')
        Assert-CcodTrue ($endIndex -ge 0 -and $unbindIndex -gt $endIndex -and $notifyDisposeIndex -gt $unbindIndex -and $menuDisposeIndex -gt $notifyDisposeIndex) 'shutdown ends, unbinds, then disposes the framework-owned menu'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'renders the optional External renderer handoff warning while keeping the active tooltip' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation
        $presentation.Color='Yellow'
        $presentation.StateKey='RendererHandoff'
        Set-CcodTrayPresentation -Context $context -Presentation $presentation -Catalog $script:TestEnglishCatalog -LanguageMode en-US -SystemCultureName en-US
        Assert-CcodEqual 'Connection: Connected' $context.NotifyIcon.Properties.Text 'legacy diagnostic tray maps the active tooltip to current connected evidence'
        Assert-CcodEqual 'Yellow' $context.NotifyIcon.Properties.Icon.Color 'legacy diagnostic renderer warning keeps its warning icon'
        Assert-CcodEqual 'Connection: Error' $context.Items.Status.Properties.Text 'legacy diagnostic renderer warning maps to the v2 error connection text'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'rejects an invalid presentation color before NotifyIcon mutation or icon allocation' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation;$presentation.Color='Blue'
        $notifyMutations=@($fake.State.Calls|Where-Object {$_ -like 'Set:TrayNotifyIcon:*'}).Count
        $iconResourceCalls=@($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count
        Assert-CcodThrows {Set-CcodTrayPresentation -Context $context -Presentation $presentation} 'CCOD_TRAY_INPUT_INVALID'
        Assert-CcodEqual $notifyMutations @($fake.State.Calls|Where-Object {$_ -like 'Set:TrayNotifyIcon:*'}).Count 'invalid color does not mutate NotifyIcon'
        Assert-CcodEqual $iconResourceCalls @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count 'invalid color allocates or disposes no icon resources'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'rejects malformed presentation display data and wrong-thread or closed updates before touching controls' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        $base=New-CcodValidPresentation
        $extra=[pscustomobject][ordered]@{};foreach($property in $base.PSObject.Properties){$extra|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value};$extra|Add-Member Extra $true
        $badState=New-CcodValidPresentation;$badState.StateKey='active'
        $badVisible=New-CcodValidPresentation;$badVisible.SessionReadyVisible='true'
        foreach($case in @(
            {Set-CcodTrayPresentation -Context $context -Presentation $extra},
            {Set-CcodTrayPresentation -Context $context -Presentation $badState},
            {Set-CcodTrayPresentation -Context $context -Presentation $badVisible}
        )){Assert-CcodThrows $case 'CCOD_TRAY_INPUT_INVALID'}
        $fake.State.ThreadId=38
        Assert-CcodThrows {Set-CcodTrayPresentation -Context $context -Presentation $base} 'CCOD_TRAY_THREAD_INVALID'
        $fake.State.ThreadId=37
        [void](Close-CcodTrayContext -Context $context)
        Assert-CcodThrows {Set-CcodTrayPresentation -Context $context -Presentation $base} 'CCOD_TRAY_CONTEXT_CLOSED'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'uses Trace first and enqueues only exact ChatGPT start hints before bounded idempotent cleanup' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$signals=[pscustomobject]@{Count=0}
    $signal={$signals.Count=$signals.Count+1}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired $signal -Adapters $fake.Adapters
    Assert-CcodEqual 'Running' $watcher.State 'watcher reaches running after registration decision'
    Assert-CcodEqual 'Trace' $watcher.Mode 'Trace is preferred'
    Assert-CcodEqual 1 $fake.State.TraceCalls 'Trace attempted once'
    Assert-CcodEqual 'Win32_ProcessStartTrace' $fake.State.TraceClass 'Trace capability class is exact'
    Assert-CcodEqual 0 $fake.State.IntrinsicCalls 'Intrinsic not attempted after Trace success'
    foreach($case in @(
        @([uint32]123,'chatgpt.exe'),@([uint32]123,'Other.exe'),@('123','ChatGPT.exe'),@([uint32]0,'ChatGPT.exe'),@([uint32]2147483648,'ChatGPT.exe')
    )){
        $callbackOutput=@(& $fake.State.TraceHandler $case[0] $case[1])
        Assert-CcodEqual 0 $callbackOutput.Count 'rejected watcher hint emits no output'
    }
    Assert-CcodEqual 0 $queue.Count 'name and PID lookalikes are ignored'
    $callbackOutput=@(& $fake.State.TraceHandler ([uint32]123) 'ChatGPT.exe')
    Assert-CcodEqual 0 $callbackOutput.Count 'valid watcher callback emits no output'
    Assert-CcodEqual 1 $queue.Count 'one valid hint is queued'
    $event=$queue.Peek()
    Assert-CcodEqual 'ProcessId,EventKind,ObservedAtUtc' (($event.PSObject.Properties.Name)-join ',') 'watcher event has exact ordered fields'
    Assert-CcodEqual 123 $event.ProcessId 'UInt32 PID is converted losslessly to Int32'
    Assert-CcodEqual 'Started' $event.EventKind 'event kind is fixed'
    Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $event.ObservedAtUtc 'event time is canonical UTC o'
    $staleCallback=$fake.State.TraceHandler
    $first=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 'SchemaVersion,Stopped,CleanupCodes' (($first.PSObject.Properties.Name)-join ',') 'stop receipt has exact fields'
    Assert-CcodEqual $true $first.Stopped 'watcher stops'
    Assert-CcodEqual 0 @($first.CleanupCodes).Count 'normal stop has no cleanup failure'
    Assert-CcodEqual 0 $queue.Count 'stop drains queued hints in finally'
    Assert-CcodEqual 'WatcherDetach,WatcherUnregister,WatcherRemoveJob,WatcherDispose' ((@($fake.State.Calls|Where-Object {$_ -like 'Watcher*'})|ForEach-Object {($_ -split ':')[0]})-join ',') 'watcher cleanup stage order is exact'
    $callCount=$fake.State.Calls.Count
    $second=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual $callCount $fake.State.Calls.Count 'second stop invokes no adapter'
    Assert-CcodEqual $true $second.Stopped 'second stop reuses terminal receipt'
    Assert-CcodEqual 0 @(& $staleCallback ([uint32]124) 'ChatGPT.exe').Count 'stale stopped callback emits nothing'
    Assert-CcodEqual 0 $queue.Count 'stale stopped callback does not enqueue'
}))

$results.Add((Invoke-CcodTest 'falls through Trace to Intrinsic and then ReconciliationOnly on every registration capability failure' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue
    $state=$fake.State
    $fake.Adapters.RegisterTrace={param($SourceIdentifier,$ClassName,$Callback)$state.TraceCalls++;throw "C:\private\trace`n--token hunter2"}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'Intrinsic' $watcher.Mode 'Trace exception falls through to Intrinsic'
    Assert-CcodEqual 1 $state.TraceCalls 'failed Trace attempted once'
    Assert-CcodEqual 1 $state.IntrinsicCalls 'Intrinsic attempted once'
    Assert-CcodEqual ([string]::Join("`r`n",@('SELECT * FROM __InstanceCreationEvent WITHIN 1',"WHERE TargetInstance ISA 'Win32_Process'","AND TargetInstance.Name = 'ChatGPT.exe'"))) $state.IntrinsicQuery 'Intrinsic query is exact multiline text'
    Assert-CcodTrue (@($state.Calls|Where-Object {$_ -like 'WatcherAttemptCleanup:ccod-process-*'}).Count -ge 1) 'failed Trace cleans only its requested private source'
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null

    $fake2=New-CcodTrayFakeAdapters;$state2=$fake2.State
    $fake2.Adapters.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $state2.TraceCalls++;Write-Warning 'SECRET_TRACE_WARNING'
        $state2.ActiveSources[$SourceIdentifier]=[pscustomobject]@{Kind='LeakedTraceResource'}
        [pscustomobject][ordered]@{SourceIdentifier='ccod-process-ffffffffffffffffffffffffffffffff';JobId=999;Resource=[pscustomobject]@{Kind='Malicious'}}
    }.GetNewClosure()
    $fake2.Adapters.RegisterIntrinsic={param($SourceIdentifier,$Query,$Callback)$state2.IntrinsicCalls++;throw 'SECRET_INTRINSIC_FAILURE'}.GetNewClosure()
    $watcher2=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher2.Mode 'diagnostic and exception degrade without public raw error'
    Assert-CcodEqual 1 $state2.TraceCalls 'diagnostic Trace attempted once'
    Assert-CcodEqual 1 $state2.IntrinsicCalls 'failed Intrinsic attempted once'
    Assert-CcodEqual 0 @($state2.Calls|Where-Object {$_ -ceq 'WatcherRemoveJob:999'}).Count 'invalid receipt job is never trusted for cleanup'
    Assert-CcodEqual 0 @($state2.Calls|Where-Object {$_ -like 'WatcherAttemptCleanup:ccod-process-ffffffff*'}).Count 'invalid receipt source is never trusted for cleanup'
    Assert-CcodEqual 2 @($state2.Calls|Where-Object {$_ -like 'WatcherAttemptCleanup:ccod-process-*'}).Count 'each failed attempt cleans only its generated source once'
    Assert-CcodEqual 0 $state2.ActiveSources.Count 'failed attempt cleanup leaves no registered fake resource'
    Stop-CcodProcessWatcher -Watcher $watcher2|Out-Null
}))

$results.Add((Invoke-CcodTest 'never cleans or registers an invalid or repeated generated watcher source' {
    $fake=New-CcodTrayFakeAdapters;$cleanup=[pscustomobject]@{Count=0}
    $fake.Adapters.NewSourceIdentifier={'existing-production-source'}
    $fake.Adapters.CleanupWatcherAttempt={param($Source)$cleanup.Count++}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher.Mode 'invalid generated sources degrade without mutation'
    Assert-CcodEqual 0 $fake.State.TraceCalls 'invalid source never reaches Trace register'
    Assert-CcodEqual 0 $fake.State.IntrinsicCalls 'invalid source never reaches Intrinsic register'
    Assert-CcodEqual 0 $cleanup.Count 'invalid source never reaches cleanup adapter'
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null

    $fake2=New-CcodTrayFakeAdapters;$same='ccod-process-33333333333333333333333333333333';$cleanup2=[pscustomobject]@{Count=0};$state2=$fake2.State
    $fake2.Adapters.NewSourceIdentifier={$same}.GetNewClosure()
    $fake2.Adapters.RegisterTrace={param($Source,$Class,$Callback)$state2.TraceCalls++;throw 'trace failed'}.GetNewClosure()
    $fake2.Adapters.CleanupWatcherAttempt={param($Source)$cleanup2.Count++}.GetNewClosure()
    $watcher2=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    Assert-CcodEqual 1 $state2.TraceCalls 'first exact source attempts Trace once'
    Assert-CcodEqual 0 $state2.IntrinsicCalls 'repeated source never reaches Intrinsic register'
    Assert-CcodEqual 1 $cleanup2.Count 'only the actually attempted Trace source is cleaned'
    Stop-CcodProcessWatcher -Watcher $watcher2|Out-Null
}))

$results.Add((Invoke-CcodTest 'bounds watcher hints and signals full reconciliation once per continuous overflow episode' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;foreach($n in 1..256){$queue.Enqueue($n)}
    $signals=[pscustomobject]@{Count=0};$signal={$signals.Count=$signals.Count+1}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired $signal -Adapters $fake.Adapters
    @(& $fake.State.TraceHandler ([uint32]301) 'ChatGPT.exe')|Out-Null
    @(& $fake.State.TraceHandler ([uint32]302) 'ChatGPT.exe')|Out-Null
    Assert-CcodEqual 256 $queue.Count 'overflow hints are dropped or coalesced'
    Assert-CcodEqual 1 $signals.Count 'continuous overflow signals once'
    Assert-CcodEqual $true $watcher.FullReconciliationNeeded 'overflow sets full reconciliation flag'
    [void]$queue.Dequeue()
    @(& $fake.State.TraceHandler ([uint32]303) 'ChatGPT.exe')|Out-Null
    Assert-CcodEqual 256 $queue.Count 'capacity becomes usable for a later exact hint'
    @(& $fake.State.TraceHandler ([uint32]304) 'ChatGPT.exe')|Out-Null
    Assert-CcodEqual 2 $signals.Count 'new overflow episode signals exactly once again'
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null
}))

$results.Add((Invoke-CcodTest 'rejects initial queue and adapter contracts before any UI or watcher mutation' {
    foreach($variant in @('TooLarge','Coercive','Diagnostic')){
        $fake=New-CcodTrayFakeAdapters
        if($variant -ceq 'TooLarge'){$fake.Adapters.GetQueueCount={param($Queue)[int]257}}
        elseif($variant -ceq 'Coercive'){$fake.Adapters.GetQueueCount={param($Queue)'0'}}
        else{$fake.Adapters.GetQueueCount={param($Queue)Write-Warning 'SECRET_COUNT';[int]0}}
        Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_INPUT_INVALID'
        Assert-CcodEqual 0 @($fake.State.Calls|Where-Object {$_ -like 'Create:*'}).Count "$variant queue rejection creates no UI"
    }
    $fake=New-CcodTrayFakeAdapters
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters @{UnknownAdapter={}}} 'CCOD_TRAY_INPUT_INVALID'
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters @{GetUtcNow='not-a-scriptblock'}} 'CCOD_TRAY_INPUT_INVALID'
    $fake.State.Apartment='MTA'
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_THREAD_INVALID'
    Assert-CcodEqual 0 @($fake.State.Calls|Where-Object {$_ -like 'Create:*'}).Count 'non-STA rejection creates no UI'
}))

$results.Add((Invoke-CcodTest 'continues every tray and watcher cleanup stage with bounded allowlisted receipts' {
    $fake=New-CcodTrayFakeAdapters;$context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $context.CleanupCodes.Add('SECRET_PRESEEDED_CODE')
    $cleanup=[pscustomobject]@{Hide=0;MenuEnd=0;Stop=0;Ui=0;Icon=0;Detach=0;Exit=0}
    $context.Adapters.SetUiVisible={param($Object,$Visible)$cleanup.Hide++;throw 'SECRET_HIDE'}.GetNewClosure()
    $context.MenuOpen=$true
    $context.Adapters.EndMenu={$cleanup.MenuEnd++;throw 'SECRET_MENU_END'}.GetNewClosure()
    $context.Adapters.StopUiTimer={param($Timer)$cleanup.Stop++;throw 'SECRET_STOP'}.GetNewClosure()
    $context.Adapters.DisposeUiObject={param($Object)$cleanup.Ui++;throw 'SECRET_UI'}.GetNewClosure()
    $context.Adapters.DisposeIconResource={param($Object)$cleanup.Icon++;throw 'SECRET_ICON'}.GetNewClosure()
    $context.Adapters.DetachUiCallback={param($Receipt)$cleanup.Detach++;throw 'SECRET_DETACH'}.GetNewClosure()
    $context.Adapters.ExitUiContext={param($Object)$cleanup.Exit++;throw 'SECRET_EXIT'}.GetNewClosure()
    $receipt=Close-CcodTrayContext -Context $context
    $expected='CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED,CCOD_TRAY_CLEANUP_NATIVE_MENU_END_FAILED,CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED,CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED,CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED,CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED'
    Assert-CcodEqual $expected (@($receipt.CleanupCodes)-join ',') 'tray cleanup codes are ordered deduplicated and allowlisted'
    Assert-CcodTrue ($cleanup.Hide -ge 1 -and $cleanup.MenuEnd -eq 1 -and $cleanup.Stop -eq 1 -and $cleanup.Ui -eq 4 -and $cleanup.Icon -eq 8 -and $cleanup.Detach -ge 12 -and $cleanup.Exit -eq 1) 'all ContextMenu cleanup stages continue despite a menu cancellation failure'
    Assert-CcodTrue (($receipt|ConvertTo-Json -Compress) -cnotmatch 'SECRET') 'tray receipt exposes no injected text'

    $fake2=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired {} -Adapters $fake2.Adapters;$queue.Enqueue('hint')
    $watcher.CleanupCodes.Add('SECRET_PRESEEDED_CODE')
    $wcalls=[pscustomobject]@{Detach=0;Unregister=0;Remove=0;Dispose=0}
    $watcher.Adapters.DetachWatcherCallback={param($x)$wcalls.Detach++;throw 'SECRET'}.GetNewClosure()
    $watcher.Adapters.UnregisterWatcher={param($x)$wcalls.Unregister++;throw 'SECRET'}.GetNewClosure()
    $watcher.Adapters.RemoveWatcherJob={param($x)$wcalls.Remove++;throw 'SECRET'}.GetNewClosure()
    $watcher.Adapters.DisposeWatcherResource={param($x)$wcalls.Dispose++;throw 'SECRET'}.GetNewClosure()
    $wreceipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 'CCOD_WATCHER_CLEANUP_CALLBACK_DETACH_FAILED,CCOD_WATCHER_CLEANUP_UNREGISTER_FAILED,CCOD_WATCHER_CLEANUP_JOB_REMOVE_FAILED,CCOD_WATCHER_CLEANUP_RESOURCE_DISPOSE_FAILED' (@($wreceipt.CleanupCodes)-join ',') 'watcher cleanup codes are exact and sanitized'
    Assert-CcodEqual '1,1,1,1' "$($wcalls.Detach),$($wcalls.Unregister),$($wcalls.Remove),$($wcalls.Dispose)" 'all watcher cleanup stages run once'
    Assert-CcodEqual 0 $queue.Count 'queue drains despite watcher cleanup failures'
}))

$results.Add((Invoke-CcodTest 'contains all six PowerShell streams and returns only fixed null-target public errors' {
    foreach($stream in @('Output','Error','Warning','Verbose','Debug','Information')){
        $fake=New-CcodTrayFakeAdapters;$secret="SECRET_STREAM_$stream"
        $fake.Adapters.SetUiProperty={
            param($Object,$Name,$Value)
            switch($stream){
                'Output'{Write-Output $secret};'Error'{Write-Error $secret -ErrorAction Continue};'Warning'{Write-Warning $secret}
                'Verbose'{Write-Verbose $secret};'Debug'{Write-Debug $secret};'Information'{Write-Information $secret}
            }
        }.GetNewClosure()
        $caught=$null;try{New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters|Out-Null}catch{$caught=$_}
        Assert-CcodTrue ($null -ne $caught) "$stream adapter diagnostic is rejected"
        Assert-CcodEqual 'CCOD_TRAY_CREATE_FAILED' (($caught.FullyQualifiedErrorId -split ',')[0]) "$stream maps to fixed create ID"
        Assert-CcodEqual 'The tray UI operation failed safely.' $caught.Exception.Message "$stream maps to fixed message"
        Assert-CcodEqual $null $caught.TargetObject "$stream has null target"
        Assert-CcodTrue (-not (($caught|Out-String).Contains($secret))) "$stream secret is contained"
        Assert-CcodTrue (-not (($Error|Out-String).Contains($secret))) "$stream secret is removed from caller error history"
    }
}))

$results.Add((Invoke-CcodTest 'removes a new adapter error from a full caller history without removing the old head' {
    $savedErrors=@($global:Error)
    try{
        $global:Error.Clear()
        $oldHead=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('OLD_HEAD'),'OLD_HEAD',[Management.Automation.ErrorCategory]::NotSpecified,$null)
        [void]$global:Error.Add($oldHead)
        foreach($index in 1..255){
            $old=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("OLD_$index"),"OLD_$index",[Management.Automation.ErrorCategory]::NotSpecified,$null)
            [void]$global:Error.Add($old)
        }
        Assert-CcodEqual 256 $global:Error.Count 'caller error history is full before the adapter runs'
        $secret='SECRET_FULL_ERROR_HISTORY'
        $callback={Write-Error $secret -ErrorAction Continue}.GetNewClosure()
        $module=Get-Module TrayUi
        $capture=& $module {param($Callback)Invoke-CcodTrayAdapterCapture $Callback @()} $callback
        Assert-CcodEqual 1 @($capture.Items).Count 'adapter error remains captured as a diagnostic stream'
        Assert-CcodTrue ([object]::ReferenceEquals($oldHead,$global:Error[0])) 'cleanup stops at the caller old head object'
        Assert-CcodTrue (-not (($global:Error|Out-String).Contains($secret))) 'new secret error is absent from caller history even when count never grew'
    }finally{
        $global:Error.Clear()
        foreach($old in $savedErrors){[void]$global:Error.Add($old)}
    }
}))

$results.Add((Invoke-CcodTest 'rejects suppressed adapter errors and restores the complete caller error history' {
    $savedErrors=@($global:Error)
    try{
        $global:Error.Clear()
        $before=[Collections.Generic.List[object]]::new()
        foreach($index in 1..4){
            $old=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("OLD_SUPPRESSED_$index"),"OLD_SUPPRESSED_$index",[Management.Automation.ErrorCategory]::NotSpecified,$null)
            $before.Add($old);[void]$global:Error.Add($old)
        }
        $secret='SECRET_SUPPRESSED_ERROR_HISTORY'
        $callback={foreach($index in 1..40){Write-Error "$secret`_$index" -ErrorAction SilentlyContinue};'valid'}.GetNewClosure()
        $module=Get-Module TrayUi
        $capture=& $module {param($Callback)Invoke-CcodTrayAdapterCapture $Callback @()} $callback
        Assert-CcodEqual $true $capture.Threw 'suppressed Error-stream records make the adapter capture fail'
        Assert-CcodEqual 4 $global:Error.Count 'caller error history count is restored exactly'
        for($index=0;$index -lt $before.Count;$index++){
            Assert-CcodTrue ([object]::ReferenceEquals($before[$index],$global:Error[$index])) "caller error history reference and order $index are restored"
        }
        Assert-CcodTrue (-not (($global:Error|Out-String).Contains($secret))) 'no suppressed adapter secret remains in caller error history'
    }finally{
        $global:Error.Clear()
        foreach($old in $savedErrors){[void]$global:Error.Add($old)}
    }
}))

$results.Add((Invoke-CcodTest 'normalizes three forged public handles before any monitor operation' {
    $presentation=New-CcodValidPresentation
    $forgedContext=[pscustomobject]@{State='Open';Adapters=@{}}
    $forgedContext.PSObject.TypeNames.Insert(0,'Ccod.TrayContext')
    $forgedWatcher=[pscustomobject]@{State='Running';Adapters=@{}}
    $forgedWatcher.PSObject.TypeNames.Insert(0,'Ccod.ProcessWatcher')
    $cases=@(
        [pscustomobject]@{Name='Set';ExpectedId='CCOD_TRAY_INPUT_INVALID';ExpectedMessage='The tray UI operation failed safely.';Action={Set-CcodTrayPresentation -Context $forgedContext -Presentation $presentation}.GetNewClosure()},
        [pscustomobject]@{Name='Close';ExpectedId='CCOD_TRAY_INPUT_INVALID';ExpectedMessage='The tray UI operation failed safely.';Action={Close-CcodTrayContext -Context $forgedContext}.GetNewClosure()},
        [pscustomobject]@{Name='Stop';ExpectedId='CCOD_WATCHER_INPUT_INVALID';ExpectedMessage='The process watcher operation failed safely.';Action={Stop-CcodProcessWatcher -Watcher $forgedWatcher}.GetNewClosure()}
    )
    foreach($case in $cases){
        $caught=$null
        try{& $case.Action|Out-Null}catch{$caught=$_}
        Assert-CcodTrue ($null -ne $caught) "$($case.Name) rejects a forged handle"
        Assert-CcodEqual $case.ExpectedId (($caught.FullyQualifiedErrorId -split ',')[0]) "$($case.Name) maps to its fixed input ID"
        Assert-CcodEqual $case.ExpectedMessage $caught.Exception.Message "$($case.Name) maps to its fixed message"
        Assert-CcodEqual $null $caught.TargetObject "$($case.Name) has a null target"
    }
}))

$results.Add((Invoke-CcodTest 'accepts the exact Closing snapshot after OnTick is cleared and returns its provisional receipt' {
    $fake=New-CcodTrayFakeAdapters
    $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $originalOnTick=$context.OnTick
    $provisional=[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=@()}
    try{
        $context.State='Closing';$context.OnTick=$null;$context.CloseReceipt=$provisional
        $returned=Close-CcodTrayContext -Context $context
        Assert-CcodTrue ([object]::ReferenceEquals($provisional,$returned)) 'second Close returns the same provisional receipt after waiting its gate'
    }finally{
        $context.State='Open';$context.OnTick=$originalOnTick;$context.CloseReceipt=$null
        Close-CcodTrayContext -Context $context|Out-Null
    }
}))

$results.Add((Invoke-CcodTest 'accepts every exact Stopping callback-clear snapshot and returns its provisional receipt' {
    $fake=New-CcodTrayFakeAdapters
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    $originalCallback=$watcher.Callback;$originalSignal=$watcher.OnFullReconciliationRequired
    $provisional=[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=@()}
    try{
        $cases=@(
            [pscustomobject]@{Name='callback-cleared-first';Callback=$null;Signal=$originalSignal},
            [pscustomobject]@{Name='signal-cleared';Callback=$originalCallback;Signal=$null},
            [pscustomobject]@{Name='both-cleared';Callback=$null;Signal=$null}
        )
        foreach($case in $cases){
            $watcher.State='Stopping';$watcher.Callback=$case.Callback;$watcher.OnFullReconciliationRequired=$case.Signal;$watcher.StopReceipt=$provisional
            $returned=Stop-CcodProcessWatcher -Watcher $watcher
            Assert-CcodTrue ([object]::ReferenceEquals($provisional,$returned)) "$($case.Name) returns the same provisional receipt after waiting its gate"
        }
    }finally{
        $watcher.State='Running';$watcher.Callback=$originalCallback;$watcher.OnFullReconciliationRequired=$originalSignal;$watcher.StopReceipt=$null
        Stop-CcodProcessWatcher -Watcher $watcher|Out-Null
    }
}))

$results.Add((Invoke-CcodTest 'recovers every retained ContextMenu UI bitmap HICON clone and attachment emitted before a diagnostic failure' {
    foreach($stage in @('CreateUiObject','AddUiChild','CreateBitmap','GetHicon','CloneIcon','AttachUiCallback')){
        $fake=New-CcodTrayFakeAdapters;$original=$fake.Adapters[$stage]
        switch($stage){
            'CreateUiObject' {$fake.Adapters[$stage]={param($Kind,$Name)$value=& $original $Kind $Name;$value;Write-Warning 'SECRET_AFTER_UI'}.GetNewClosure()}
            'AddUiChild' {$fake.Adapters[$stage]={param($Parent,$Child)& $original $Parent $Child;Write-Warning 'SECRET_AFTER_MENU_CHILD'}.GetNewClosure()}
            'CreateBitmap' {$fake.Adapters[$stage]={param($Color,$Size)$value=& $original $Color $Size;$value;Write-Warning 'SECRET_AFTER_BITMAP'}.GetNewClosure()}
            'GetHicon' {$fake.Adapters[$stage]={param($Bitmap)$value=& $original $Bitmap;$value;Write-Warning 'SECRET_AFTER_HICON'}.GetNewClosure()}
            'CloneIcon' {$fake.Adapters[$stage]={param($Hicon,$Color,$Size)$value=& $original $Hicon $Color $Size;$value;Write-Warning 'SECRET_AFTER_CLONE'}.GetNewClosure()}
            'AttachUiCallback' {$fake.Adapters[$stage]={param($Object,$EventName,$Callback)$value=& $original $Object $EventName $Callback;$value;Write-Warning 'SECRET_AFTER_ATTACH'}.GetNewClosure()}
        }
        Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
        Assert-CcodTrue (@($fake.State.Objects|Where-Object {$_.DisposeCount -gt 1}).Count -eq 0) "$stage never double-disposes a UI object"
        Assert-CcodTrue (@($fake.State.Bitmaps|Where-Object {$_.DisposeCount -ne 1}).Count -eq 0) "$stage disposes every created bitmap once"
        Assert-CcodTrue (@($fake.State.IconClones|Where-Object {$_.DisposeCount -ne 1}).Count -eq 0) "$stage disposes every created clone once"
        if($stage -ceq 'GetHicon'){Assert-CcodEqual 1 @($fake.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'diagnostic HICON is still destroyed'}
        if($stage -ceq 'AttachUiCallback'){Assert-CcodTrue (@($fake.State.Calls|Where-Object {$_ -like 'Detach:*'}).Count -ge 1) 'diagnostic ContextMenu attachment is detached immediately'}
    }
    $invalid=New-CcodTrayFakeAdapters;$invalid.Adapters.GetHicon={param($Bitmap)'1001';Write-Warning 'invalid hicon'}
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $invalid.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    Assert-CcodEqual 0 @($invalid.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'invalid HICON-shaped output is never passed to DestroyIcon'
    $duplicate=New-CcodTrayFakeAdapters;$originalHicon=$duplicate.Adapters.GetHicon
    $duplicate.Adapters.GetHicon={param($Bitmap)$value=& $originalHicon $Bitmap;$value;$value;Write-Warning 'duplicate hicon'}.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $duplicate.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    Assert-CcodEqual 1 @($duplicate.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'duplicate exact HICON output is destroyed once'
}))

$results.Add((Invoke-CcodTest 'recovers the seventeenth recognizable owned UI object and HICON without double cleanup' {
    $uiFake=New-CcodTrayFakeAdapters
    $created=[Collections.Generic.List[object]]::new();$uiState=$uiFake.State
    $uiFake.Adapters.CreateUiObject={
        param($Kind,$Name)
        foreach($index in 1..17){
            $object=[pscustomobject]@{Kind=$Kind;Name="$Name-$index";Properties=[ordered]@{IsDisposed=$false};Events=[ordered]@{};Children=[Collections.Generic.List[object]]::new();Disposed=$false;DisposeCount=0}
            $created.Add($object);$uiState.Objects.Add($object);$object
        }
    }.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $uiFake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    Assert-CcodEqual 17 $created.Count 'owned factory emitted exactly seventeen recognizable UI objects'
    Assert-CcodEqual 17 @($created|Where-Object {$_.DisposeCount -eq 1}).Count 'all seventeen UI objects are disposed exactly once'
    Assert-CcodEqual 0 @($created|Where-Object {$_.DisposeCount -gt 1}).Count 'overflow UI object is never double-disposed'

    $hiconFake=New-CcodTrayFakeAdapters;$hiconSeed=[pscustomobject]@{Value=3000}
    $hiconFake.Adapters.GetHicon={
        param($Bitmap)
        foreach($index in 1..17){$hiconSeed.Value++;[IntPtr]$hiconSeed.Value}
    }.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $hiconFake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    $destroyed=@($hiconFake.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'})
    Assert-CcodEqual 17 $destroyed.Count 'all seventeen recognizable HICON outputs are destroyed'
    Assert-CcodEqual 17 @($destroyed|Select-Object -Unique).Count 'every overflow HICON is destroyed exactly once'
}))

$results.Add((Invoke-CcodTest 'stops fallback after failed attempt cleanup and retries only that exact source during Stop' {
    $fake=New-CcodTrayFakeAdapters;$state=$fake.State;$cleanup=[pscustomobject]@{Calls=0;Source=$null}
    $fake.Adapters.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $state.TraceCalls++;$state.TraceHandler=$Callback;$state.ActiveSources[$SourceIdentifier]=[pscustomobject]@{Kind='TracePartial'}
        Write-Warning 'SECRET_PARTIAL';[pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=11;Resource=$state.ActiveSources[$SourceIdentifier]}
    }.GetNewClosure()
    $fake.Adapters.CleanupWatcherAttempt={
        param($SourceIdentifier)
        $cleanup.Calls++;$cleanup.Source=$SourceIdentifier
        if($cleanup.Calls -eq 1){throw 'SECRET_CLEANUP'}
        [void]$state.ActiveSources.Remove($SourceIdentifier)
    }.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher.Mode 'cleanup failure forces reconciliation-only mode'
    Assert-CcodEqual 0 $state.IntrinsicCalls 'cleanup failure never stacks Intrinsic registration'
    Assert-CcodEqual 1 $watcher.PendingAttemptSources.Count 'failed exact source is retained for Stop retry'
    $stale=$state.TraceHandler
    $receipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 2 $cleanup.Calls 'Stop retries attempt cleanup exactly once'
    Assert-CcodEqual 0 $state.ActiveSources.Count 'retry removes the partial fake registration'
    Assert-CcodEqual 0 @($receipt.CleanupCodes).Count 'successful Stop retry leaves clean receipt'
    Assert-CcodEqual 0 @(& $stale ([uint32]22) 'ChatGPT.exe').Count 'stale partial callback is stopped no-op'
}))

$results.Add((Invoke-CcodTest 'persists a discovered side-effect job before unregister and removes it on Stop retry' {
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    Assert-CcodEqual 0 @($parseErrors).Count 'production cleanup source parses before isolated execution'
    $defaultFunction=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CcodTrayDefaultAdapters'},$true))[0]
    $cleanupAssignment=@($defaultFunction.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$defaults.CleanupWatcherAttempt'
    },$true))[0]
    $cleanupExpression=@($cleanupAssignment.FindAll({param($node)$node -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true))[0]
    $productionCleanup=$cleanupExpression.ScriptBlock.GetScriptBlock()

    $source='ccod-process-'+('a'*32)
    $world=[pscustomobject]@{
        Subscribers=[Collections.Generic.List[object]]::new();Jobs=@{};RemoveCalls=0;UnregisterCalls=0;GetSubscriberCalls=0;GetJobCalls=0
    }
    $attempts=@{}
    $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
    $variables.Add([Management.Automation.PSVariable]::new('watcherAttemptJobs',$attempts))
    $variables.Add([Management.Automation.PSVariable]::new('watcherAttemptJobLimit',[int]16))
    $fakeCommands=@{
        'Get-EventSubscriber'={param($ErrorAction)$world.GetSubscriberCalls++;@($world.Subscribers)}.GetNewClosure()
        'Unregister-Event'={param($SourceIdentifier,$ErrorAction)$world.UnregisterCalls++;$world.Subscribers.Clear()}.GetNewClosure()
        'Get-Job'={param($ErrorAction)$world.GetJobCalls++;@($world.Jobs.Values)}.GetNewClosure()
        'Remove-Job'={
            param($Id,[switch]$Force,$ErrorAction)
            $world.RemoveCalls++
            if($world.RemoveCalls -eq 1){throw 'FAKE_FIRST_REMOVE_FAILURE'}
            [void]$world.Jobs.Remove([int]$Id)
        }.GetNewClosure()
    }
    $fake=New-CcodTrayFakeAdapters;$state=$fake.State
    $fake.Adapters.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $state.TraceCalls++;$state.TraceHandler=$Callback
        $world.Subscribers.Add([pscustomobject]@{SourceIdentifier=$SourceIdentifier;Action=[pscustomobject]@{Id=[int]321}})
        $world.Jobs[[int]321]=[pscustomobject]@{Id=[int]321}
        throw 'FAKE_REGISTER_SIDE_EFFECT_THEN_THROW'
    }.GetNewClosure()
    $fake.Adapters.CleanupWatcherAttempt={
        param($SourceIdentifier)
        $productionCleanup.InvokeWithContext($fakeCommands,$variables,[object[]]@($SourceIdentifier))|Out-Null
    }.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher.Mode 'failed cleanup prevents Intrinsic stacking after a side-effecting Trace throw'
    Assert-CcodEqual 0 $state.IntrinsicCalls 'Intrinsic is not attempted while the side-effect job remains'
    Assert-CcodEqual 1 $world.UnregisterCalls 'first cleanup unregisters the exact discovered subscriber'
    Assert-CcodEqual 1 $world.RemoveCalls 'first cleanup observes the injected job-removal failure'
    Assert-CcodEqual 1 $world.Jobs.Count 'failed first removal leaves the fake job observable'
    $receipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 2 $world.RemoveCalls 'Stop retries the persisted exact discovered job ID'
    Assert-CcodEqual 0 $world.Jobs.Count 'Stop retry removes the orphan candidate completely'
    Assert-CcodEqual 0 @($receipt.CleanupCodes).Count 'successful retry has no cleanup failure receipt'
}))

$results.Add((Invoke-CcodTest 'drains exactly 256 hints cleanly caps 257 and detects an early false dequeue' {
    $fake=New-CcodTrayFakeAdapters;$full=New-CcodTrayTestQueue;foreach($n in 1..256){$full.Enqueue($n)}
    $watcher=Start-CcodProcessWatcher -Queue $full -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    $receipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 0 $full.Count 'exact 256 queue drains completely'
    Assert-CcodEqual 0 @($receipt.CleanupCodes).Count 'exact 256 drain does not misreport limit'

    $fake2=New-CcodTrayFakeAdapters;$over=New-CcodTrayTestQueue;$watcher2=Start-CcodProcessWatcher -Queue $over -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    foreach($n in 1..257){$over.Enqueue($n)}
    $receipt2=Stop-CcodProcessWatcher -Watcher $watcher2
    Assert-CcodEqual 1 $over.Count '257 queue performs no more than 256 dequeues'
    Assert-CcodEqual 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_LIMIT' (@($receipt2.CleanupCodes)-join ',') '257 residual reports stable limit code'

    $fake3=New-CcodTrayFakeAdapters;$stuck=New-CcodTrayTestQueue;$watcher3=Start-CcodProcessWatcher -Queue $stuck -OnFullReconciliationRequired {} -Adapters $fake3.Adapters;$stuck.Enqueue('left')
    $watcher3.Adapters.TryDequeue={param($Queue)[pscustomobject][ordered]@{Succeeded=$false;Value=$null}}
    $receipt3=Stop-CcodProcessWatcher -Watcher $watcher3
    Assert-CcodEqual 1 $stuck.Count 'early false leaves observable residual'
    Assert-CcodEqual 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED' (@($receipt3.CleanupCodes)-join ',') 'early false residual is not claimed clean'
}))

$results.Add((Invoke-CcodTest 'latches close and stop before reentrant cleanup callbacks can dispose twice' {
    $fake=New-CcodTrayFakeAdapters;$context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $originalStop=$context.Adapters.StopUiTimer;$stops=[pscustomobject]@{Count=0}
    $context.Adapters.StopUiTimer={param($Timer)$stops.Count++;Close-CcodTrayContext -Context $context|Out-Null;& $originalStop $Timer}.GetNewClosure()
    Close-CcodTrayContext -Context $context|Out-Null
    Assert-CcodEqual 1 $stops.Count 'reentrant close does not repeat timer stop'
    Assert-CcodEqual 8 @($fake.State.IconClones|Where-Object {$_.DisposeCount -eq 1}).Count 'reentrant close disposes each owned clone once'

    $fake2=New-CcodTrayFakeAdapters;$watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    $originalDetach=$watcher.Adapters.DetachWatcherCallback;$detaches=[pscustomobject]@{Count=0}
    $watcher.Adapters.DetachWatcherCallback={param($Receipt)$detaches.Count++;Stop-CcodProcessWatcher -Watcher $watcher|Out-Null;& $originalDetach $Receipt}.GetNewClosure()
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null
    Assert-CcodEqual 1 $detaches.Count 'reentrant stop does not repeat watcher cleanup'
    Assert-CcodEqual 1 @($fake2.State.Calls|Where-Object {$_ -like 'WatcherRemoveJob:*'}).Count 'job removal occurs once'
}))

$results.Add((Invoke-CcodTest 'keeps production defaults lazy and the Task10C2 AST free of forbidden mutation surfaces' {
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    Assert-CcodEqual 0 @($parseErrors).Count 'TrayUi module parses cleanly'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$_})
    foreach($forbidden in @('Start-Process','Stop-Process','Get-AppxPackage','Set-ItemProperty','New-ItemProperty','schtasks.exe','node.exe','git.exe')){
        Assert-CcodEqual 0 @($commands|Where-Object {$_ -ceq $forbidden}).Count "$forbidden is absent from Task10C2 AST"
    }
    $text=Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('Register-WmiEvent -Class $ClassName')) 'production Trace default remains lazy source text only'
    foreach($forbiddenText in @('PresentationFramework','PresentationCore','WindowsBase','WindowsFormsIntegration','Windows.Window','PostUiCallback','Dispatcher','Topmost','NativeFallback')){
        Assert-CcodTrue (-not $text.Contains($forbiddenText)) "$forbiddenText is absent from the native tray implementation"
    }
}))

$results.Add((Invoke-CcodTest 'executes only extracted production WMI action ASTs with fake Event and MessageData values' {
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Register-WmiEvent'},$true))
    Assert-CcodEqual 2 $commands.Count 'there are exactly two production WMI registrations in source'
    $traceCommand=@($commands|Where-Object {$_.Extent.Text -cmatch '-Class\s+\$ClassName'})[0]
    $intrinsicCommand=@($commands|Where-Object {$_.Extent.Text -cmatch '-Query\s+\$Query'})[0]
    Assert-CcodTrue ($traceCommand.Extent.Text -cmatch '-MessageData\s+\$Callback') 'Trace binds callback only through MessageData'
    Assert-CcodTrue ($intrinsicCommand.Extent.Text -cmatch '-MessageData\s+\$Callback') 'Intrinsic binds callback only through MessageData'
    $traceAction=@($traceCommand.CommandElements|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[0].ScriptBlock.GetScriptBlock()
    $intrinsicAction=@($intrinsicCommand.CommandElements|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[0].ScriptBlock.GetScriptBlock()
    $seen=[pscustomobject]@{TraceId=$null;TraceName=$null;IntrinsicId=$null;IntrinsicName=$null}
    $traceCallback={param($processId,$name)$seen.TraceId=$processId;$seen.TraceName=$name}.GetNewClosure()
    $intrinsicCallback={param($processId,$name)$seen.IntrinsicId=$processId;$seen.IntrinsicName=$name}.GetNewClosure()
    $traceEvent=[pscustomobject]@{MessageData=$traceCallback;SourceEventArgs=[pscustomobject]@{NewEvent=[pscustomobject]@{ProcessID=[uint32]123;ProcessName='ChatGPT.exe'}}}
    $intrinsicEvent=[pscustomobject]@{MessageData=$intrinsicCallback;SourceEventArgs=[pscustomobject]@{NewEvent=[pscustomobject]@{TargetInstance=[pscustomobject]@{ProcessId=[uint32]124;Name='ChatGPT.exe'}}}}
    foreach($case in @(@($traceAction,$traceEvent),@($intrinsicAction,$intrinsicEvent))){
        $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new();$variables.Add([Management.Automation.PSVariable]::new('Event',$case[1]))
        $case[0].InvokeWithContext($null,$variables,[object[]]@())|Out-Null
    }
    Assert-CcodEqual ([uint32]123) $seen.TraceId 'Trace action forwards raw UInt32 without touching read-only PID'
    Assert-CcodEqual 'ChatGPT.exe' $seen.TraceName 'Trace action forwards exact name'
    Assert-CcodEqual ([uint32]124) $seen.IntrinsicId 'Intrinsic action forwards raw UInt32'
    Assert-CcodEqual 'ChatGPT.exe' $seen.IntrinsicName 'Intrinsic action forwards exact name'
    $text=Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('Remove-Job -Id $jobId -Force -ErrorAction Stop')) 'attempt cleanup never hides a real job-removal failure'
    Assert-CcodTrue ($text.Contains('$watcherAttemptJobs[$SourceIdentifier]')) 'attempt cleanup retains source-bound job identity for retry'
}))


$results += Invoke-CcodTest 'production tray icon paths dispose temporary handles and use OrderedDictionary Contains' {
    $text = Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('$temporary.Dispose()')) 'CloneIcon disposes the temporary FromHandle icon'
    Assert-CcodTrue ($text.Contains('Icons.Contains($color')) 'icon map uses OrderedDictionary Contains, not ContainsKey'
    Assert-CcodTrue (-not $text.Contains('Icons.ContainsKey(')) 'no OrderedDictionary ContainsKey misuse remains'
    Assert-CcodTrue ($text.Contains('$iconCleanupFailed -and -not $context.Icons.Contains($color')) 'icon cleanup failure is non-fatal after a successful clone'
}

$results += Invoke-CcodTest 'production AttachUiCallback handlers capture the callback scriptblock' {
    $text = Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure()')) 'event handler wraps the callback in a closure so Timer ticks survive the adapter scope'
    $needle = '[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}'
    $index = $text.IndexOf($needle)
    Assert-CcodTrue ($index -ge 0) 'event handler needle is present'
    $tail = $text.Substring($index + $needle.Length, [Math]::Min(24, $text.Length - $index - $needle.Length))
    Assert-CcodTrue ($tail.StartsWith('.GetNewClosure()')) 'every event handler needle is immediately closed over'
}

$results += Invoke-CcodTest 'maps the legacy renderer handoff label through the validated v2 catalog' {
    $localized=& (Get-Module TrayUi) {param($Catalog)Resolve-CcodTrayLocalizedStrings -Catalog $Catalog -LanguageMode en-US -SystemCultureName en-US} $script:TestEnglishCatalog
    Assert-CcodEqual 'Connection: Error' $localized['Status.RendererHandoff'] 'legacy diagnostic tray maps renderer handoff to the v2 error connection key'
}

$results|ForEach-Object{"PASS $($_.Name)"}
