Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'UiLocalization.psm1') -ErrorAction Stop

$script:TrayWinFormsLoaded=$false

$script:TrayAdapterNames=@(
    'GetUtcNow','GetQueueCount','TryEnqueue','TryDequeue','GetManagedThreadId','GetApartmentState',
    'CreateUiObject','SetUiProperty','GetUiProperty','SetUiVisible','StartUiTimer','StopUiTimer',
    'AttachUiCallback','DetachUiCallback','AddUiChild','DisposeUiObject','ExitUiContext','ShowErrorDialog','EndMenu',
    'CreateBitmap','DrawBridgeIcon','GetHicon','CloneIcon','DestroyIcon','DisposeIconResource',
    'NewSourceIdentifier','RegisterTrace','RegisterIntrinsic','CleanupWatcherAttempt','DetachWatcherCallback','UnregisterWatcher',
    'RemoveWatcherJob','DisposeWatcherResource'
)
$script:TrayUiLanguageModes=@('System','zh-CN','en-US')
$script:TrayUiCatalogKeys=@(
    'Tray.Title','Status.Waiting','Status.Inspecting','Status.Transitioning','Status.Active','Status.ActivePaused','Status.Suppressed','Status.Recovered','Status.Error','Status.RendererHandoff',
    'Tooltip.Waiting','Tooltip.Inspecting','Tooltip.Transitioning','Tooltip.Active','Tooltip.ActivePaused','Tooltip.Suppressed','Tooltip.Recovered','Tooltip.Error',
    'Menu.SessionReady','Menu.ApplyNow','Menu.ManualRetry','Menu.Automation','Menu.CandidateOptIn','Menu.Language','Menu.FollowSystem','Menu.Chinese','Menu.English','Menu.OpenLogs','Menu.About','Menu.AboutVersion',
    'Error.LanguageChange'
)
$script:TrayCleanupCodeAllowlist=@(
    'CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED','CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED','CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED',
    'CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED','CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED','CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED',
    'CCOD_TRAY_CLEANUP_CONTROL_DISPOSE_FAILED','CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED','CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED','CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED',
    'CCOD_TRAY_CLEANUP_NATIVE_MENU_END_FAILED','CCOD_TRAY_CLEANUP_NATIVE_MENU_OWNER_DISPOSE_FAILED'
)
$script:WatcherCleanupCodeAllowlist=@(
    'CCOD_WATCHER_CLEANUP_ATTEMPT_FAILED',
    'CCOD_WATCHER_CLEANUP_CALLBACK_DETACH_FAILED','CCOD_WATCHER_CLEANUP_UNREGISTER_FAILED','CCOD_WATCHER_CLEANUP_JOB_REMOVE_FAILED',
    'CCOD_WATCHER_CLEANUP_RESOURCE_DISPOSE_FAILED','CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED','CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_LIMIT'
)

function Initialize-CcodTrayWinForms {
    if($script:TrayWinFormsLoaded){return}
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $script:TrayWinFormsLoaded=$true
}

function Initialize-CcodTrayNativeMethodsV3 {
    $type='CcodTrayNativeMethodsV3' -as [type]
    if($null -eq $type){
        [void](Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class CcodTrayNativeMethodsV3 { [DllImport("user32.dll", SetLastError=true)] public static extern bool DestroyIcon(IntPtr hIcon); [DllImport("user32.dll", SetLastError=true)] public static extern bool EndMenu(); }' -PassThru -ErrorAction Stop)
        $type='CcodTrayNativeMethodsV3' -as [type]
    }
    if($null -eq $type -or $null -eq $type.GetMethod('DestroyIcon') -or $null -eq $type.GetMethod('EndMenu')){throw 'native tray method contract is unavailable'}
}

function Throw-CcodTrayError {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][ValidateSet('Tray','Watcher')][string]$Surface)
    $message=if($Surface -ceq 'Watcher'){'The process watcher operation failed safely.'}else{'The tray UI operation failed safely.'}
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($message),$Code,[Management.Automation.ErrorCategory]::InvalidOperation,$null
    )
}

function Test-CcodExactProperties {
    param($Value,[string[]]$Names)
    if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
    $actual=@($Value.PSObject.Properties.Name)
    if($actual.Count -ne $Names.Count){return $false}
    for($i=0;$i -lt $Names.Count;$i++){
        if($actual[$i] -cne $Names[$i] -or $Value.PSObject.Properties[$actual[$i]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){return $false}
    }
    return $true
}

function Test-CcodDiagnosticRecord {
    param($Value)
    return $Value -is [Management.Automation.ErrorRecord] -or $Value -is [Management.Automation.WarningRecord] -or
        $Value -is [Management.Automation.VerboseRecord] -or $Value -is [Management.Automation.DebugRecord] -or
        $Value -is [Management.Automation.InformationRecord]
}

function Test-CcodTrayCatalog {
    param($Catalog,[AllowNull()][string]$ExpectedMode=$null)
    try{
        if(-not (Test-CcodExactProperties $Catalog @('LanguageMode','EffectiveLocale','Strings','UsedEmergencyCatalog','ErrorCode')) -or
           $Catalog.LanguageMode -isnot [string] -or $script:TrayUiLanguageModes -cnotcontains $Catalog.LanguageMode -or
           (-not [string]::IsNullOrEmpty($ExpectedMode) -and $Catalog.LanguageMode -cne $ExpectedMode) -or
           $Catalog.EffectiveLocale -isnot [string] -or @('zh-CN','en-US') -cnotcontains $Catalog.EffectiveLocale -or
           $Catalog.UsedEmergencyCatalog -isnot [bool] -or
           ($null -ne $Catalog.ErrorCode -and ($Catalog.ErrorCode -isnot [string] -or @('','CCOD_UI_RESOURCE_INVALID') -cnotcontains $Catalog.ErrorCode)) -or
           -not (Test-CcodExactProperties $Catalog.Strings $script:TrayUiCatalogKeys)){return $false}
        foreach($key in $script:TrayUiCatalogKeys){
            $value=$Catalog.Strings.PSObject.Properties[$key].Value
            if($value -isnot [string] -or $value.Length -lt 1 -or $value.Length -gt 300 -or (Test-CcodControlCharacter $value)){return $false}
        }
        return $true
    }catch{return $false}
}

function ConvertTo-CcodTrayLegacyCatalog {
    param($Catalog)
    try{
        if(-not(Test-CcodExactProperties $Catalog @('LanguageMode','EffectiveLocale','Strings','UsedEmergencyCatalog','ErrorCode')) -or $null-eq$Catalog.Strings){return $Catalog}
        $required=@('Tray.Title','Connection.WaitingForCodex','Connection.Checking','Connection.Connected','Connection.RepairNeeded','Connection.Error','Menu.CheckAndRepair','Menu.Language','Menu.FollowSystem','Menu.Chinese','Menu.English','Menu.OpenLogs','Menu.About','Menu.AboutVersion','Menu.Exit','Dialog.ExitTitle','Dialog.ExitMessage','Error.ActionFailed','Error.LanguageChange')
        foreach($key in $required){$property=$Catalog.Strings.PSObject.Properties[$key];if($null-eq$property-or$property.Value-isnot[string]){return $Catalog}}
        $source=$Catalog.Strings
        $legacy=[ordered]@{
            'Tray.Title'=$source.'Tray.Title'
            'Status.Waiting'=$source.'Connection.WaitingForCodex';'Status.Inspecting'=$source.'Connection.Checking';'Status.Transitioning'=$source.'Connection.Checking';'Status.Active'=$source.'Connection.Connected';'Status.ActivePaused'=$source.'Connection.Connected';'Status.Suppressed'=$source.'Connection.RepairNeeded';'Status.Recovered'=$source.'Connection.RepairNeeded';'Status.Error'=$source.'Connection.Error';'Status.RendererHandoff'=$source.'Connection.Error'
            'Tooltip.Waiting'=$source.'Connection.WaitingForCodex';'Tooltip.Inspecting'=$source.'Connection.Checking';'Tooltip.Transitioning'=$source.'Connection.Checking';'Tooltip.Active'=$source.'Connection.Connected';'Tooltip.ActivePaused'=$source.'Connection.Connected';'Tooltip.Suppressed'=$source.'Connection.RepairNeeded';'Tooltip.Recovered'=$source.'Connection.RepairNeeded';'Tooltip.Error'=$source.'Connection.Error'
            'Menu.SessionReady'=$source.'Connection.Connected';'Menu.ApplyNow'=$source.'Menu.CheckAndRepair';'Menu.ManualRetry'=$source.'Menu.CheckAndRepair';'Menu.Automation'='Retired';'Menu.CandidateOptIn'='Retired';'Menu.Language'=$source.'Menu.Language';'Menu.FollowSystem'=$source.'Menu.FollowSystem';'Menu.Chinese'=$source.'Menu.Chinese';'Menu.English'=$source.'Menu.English';'Menu.OpenLogs'=$source.'Menu.OpenLogs';'Menu.About'=$source.'Menu.About';'Menu.AboutVersion'=$source.'Menu.AboutVersion'
            'Error.LanguageChange'=$source.'Error.LanguageChange'
        }
        return [pscustomobject][ordered]@{LanguageMode=$Catalog.LanguageMode;EffectiveLocale=$Catalog.EffectiveLocale;Strings=[pscustomobject]$legacy;UsedEmergencyCatalog=$Catalog.UsedEmergencyCatalog;ErrorCode=$Catalog.ErrorCode}
    }catch{return $Catalog}
}

function Resolve-CcodTrayLocalizedStrings {
    param($Catalog,[string]$LanguageMode,[string]$SystemCultureName)
    $Catalog=ConvertTo-CcodTrayLegacyCatalog $Catalog
    if($script:TrayUiLanguageModes -cnotcontains $LanguageMode -or $SystemCultureName -isnot [string] -or
       $SystemCultureName.Length -lt 1 -or $SystemCultureName.Length -gt 85 -or (Test-CcodControlCharacter $SystemCultureName) -or
       -not (Test-CcodTrayCatalog $Catalog $LanguageMode)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $strings=[ordered]@{}
    try{
        foreach($key in $script:TrayUiCatalogKeys){$strings[$key]=[string]$Catalog.Strings.PSObject.Properties[$key].Value}
        $systemLanguage=if($SystemCultureName -cmatch '^zh(?:-|$)'){$strings['Menu.Chinese']}else{$strings['Menu.English']}
        $strings['Menu.FollowSystem']=[string]::Format([Globalization.CultureInfo]::InvariantCulture,$strings['Menu.FollowSystem'],$systemLanguage)
    }catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    Write-Output -NoEnumerate $strings
}

function Invoke-CcodTrayAdapterCapture {
    param([scriptblock]$Callback,[object[]]$Arguments)
    if($Callback -isnot [scriptblock]){return [pscustomobject]@{Threw=$true;Items=@();OverflowItem=$null}}
    $items=[Collections.Generic.List[object]]::new();$threw=$false;$overflowItem=$null
    $startingErrors=[object[]]@($global:Error)
    $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
    foreach($name in @('ErrorActionPreference','WarningPreference','VerbosePreference','DebugPreference','InformationPreference')){
        $variables.Add([Management.Automation.PSVariable]::new($name,'Continue'))
    }
    $invoker={param($InnerCallback,$InnerVariables,$InnerArguments)$InnerCallback.InvokeWithContext($null,$InnerVariables,[object[]]$InnerArguments)}
    try{
        & $invoker $Callback $variables $Arguments *>&1|ForEach-Object{
            if($items.Count -ge 16){$overflowItem=$_;throw 'adapter output limit exceeded'}
            $items.Add($_)
        }
    }catch{$threw=$true}
    finally{
        $errorHistoryChanged=$global:Error.Count -ne $startingErrors.Count
        if(-not $errorHistoryChanged){
            for($index=0;$index -lt $startingErrors.Count;$index++){
                if(-not [object]::ReferenceEquals($startingErrors[$index],$global:Error[$index])){$errorHistoryChanged=$true;break}
            }
        }
        if($errorHistoryChanged){$threw=$true}
        $global:Error.Clear()
        foreach($startingError in $startingErrors){[void]$global:Error.Add($startingError)}
    }
    return [pscustomobject]@{Threw=[bool]$threw;Items=@($items);OverflowItem=$overflowItem}
}

function Invoke-CcodTrayAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[int]$OutputCount,[string]$FailureCode,[string]$Surface='Tray')
    $capture=Invoke-CcodTrayAdapterCapture $Callback $Arguments
    if($capture.Threw){Throw-CcodTrayError $FailureCode $Surface}
    foreach($item in $capture.Items){if(Test-CcodDiagnosticRecord $item){Throw-CcodTrayError $FailureCode $Surface}}
    if($capture.Items.Count -ne $OutputCount){Throw-CcodTrayError $FailureCode $Surface}
    if($OutputCount -eq 1){return $capture.Items[0]}
}

function Invoke-CcodTraySideEffectAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments)
    $capture=Invoke-CcodTrayAdapterCapture $Callback $Arguments
    $succeeded=-not $capture.Threw -and $capture.Items.Count -eq 0
    foreach($item in $capture.Items){if(Test-CcodDiagnosticRecord $item){$succeeded=$false}}
    return [pscustomobject][ordered]@{Completed=[bool](-not $capture.Threw);Succeeded=[bool]$succeeded}
}

function Invoke-CcodOwnedTrayAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[scriptblock]$CleanupCallback,[scriptblock]$Validator,[string]$FailureCode,[string]$Surface='Tray')
    $capture=Invoke-CcodTrayAdapterCapture $Callback $Arguments
    $outputs=@($capture.Items|Where-Object {-not (Test-CcodDiagnosticRecord $_)})
    $cleanupOutputs=@($outputs)
    if($null -ne $capture.OverflowItem -and -not (Test-CcodDiagnosticRecord $capture.OverflowItem)){$cleanupOutputs+=@($capture.OverflowItem)}
    $valid=$false
    if(-not $capture.Threw -and $capture.Items.Count -eq 1 -and $outputs.Count -eq 1){
        try{$validation=@(& $Validator $outputs[0]);$valid=$validation.Count -eq 1 -and $validation[0] -is [bool] -and $validation[0]}catch{$valid=$false}
    }
    if(-not $valid){
        $cleanupCandidates=[Collections.Generic.List[object]]::new()
        foreach($candidate in @($cleanupOutputs|Select-Object -First 17)){
            $recognizable=$false
            try{$candidateValidation=@(& $Validator $candidate);$recognizable=$candidateValidation.Count -eq 1 -and $candidateValidation[0] -is [bool] -and $candidateValidation[0]}catch{$recognizable=$false}
            $duplicate=$false
            if($recognizable){
                foreach($existing in $cleanupCandidates){
                    if([object]::ReferenceEquals($existing,$candidate) -or ($existing.GetType().IsValueType -and $existing.Equals($candidate))){$duplicate=$true;break}
                }
            }
            if($recognizable -and -not $duplicate){
                $cleanupCandidates.Add($candidate)
                $cleanupArguments=[object[]]::new(1);$cleanupArguments[0]=$candidate
                try{Invoke-CcodTrayAdapter $CleanupCallback $cleanupArguments 0 $FailureCode $Surface}catch{}
            }
        }
        Throw-CcodTrayError $FailureCode $Surface
    }
    return $outputs[0]
}

function Get-CcodTrayDefaultAdapters {
    $defaults=@{}
    $watcherAttemptJobs=@{}
    $watcherAttemptJobLimit=16
    $defaults.GetUtcNow={ [DateTimeOffset]::UtcNow }
    $defaults.GetQueueCount={param($Queue)[int]$Queue.Count}
    $defaults.TryEnqueue={param($Queue,$Value)$Queue.Enqueue($Value);$true}
    $defaults.TryDequeue={
        param($Queue)
        $value=$null
        if($Queue -is [Collections.Concurrent.ConcurrentQueue[object]]){$ok=$Queue.TryDequeue([ref]$value)}
        elseif($Queue.Count -gt 0){$value=$Queue.Dequeue();$ok=$true}else{$ok=$false}
        [pscustomobject][ordered]@{Succeeded=[bool]$ok;Value=$value}
    }
    $defaults.GetManagedThreadId={[int][Threading.Thread]::CurrentThread.ManagedThreadId}
    $defaults.GetApartmentState={[string][Threading.Thread]::CurrentThread.GetApartmentState()}
    $defaults.CreateUiObject={
        param($Kind,$Name)
        Initialize-CcodTrayWinForms
        switch($Kind){
            'ApplicationContext' {$object=New-Object Windows.Forms.ApplicationContext}
            'Timer' {$object=New-Object Windows.Forms.Timer}
            'NotifyIcon' {$object=New-Object Windows.Forms.NotifyIcon}
            'ContextMenu' {$object=New-Object Windows.Forms.ContextMenu}
            'MenuItem' {$object=New-Object Windows.Forms.MenuItem}
            default {throw 'unsupported UI object kind'}
        }
        if($object.PSObject.Properties['Name']){$object.Name=$Name}
        $object
    }
    $defaults.SetUiProperty={
        param($Object,$Name,$Value)
        Initialize-CcodTrayWinForms
        $property=$Object.PSObject.Properties[$Name]
        if($null -eq $property){throw 'unsupported native UI property'}
        $property.Value=$Value
    }
    $defaults.GetUiProperty={
        param($Object,$Name)
        Initialize-CcodTrayWinForms
        $property=$Object.PSObject.Properties[$Name]
        if($null -eq $property){throw 'unsupported native UI property'}
        $property.Value
    }
    $defaults.SetUiVisible={
        param($Object,$Visible)
        Initialize-CcodTrayWinForms
        $Object.Visible=[bool]$Visible
    }
    $defaults.StartUiTimer={param($Timer)$Timer.Start()}
    $defaults.StopUiTimer={param($Timer)$Timer.Stop()}
    $defaults.AttachUiCallback={
        param($Object,$EventName,$Callback)
        Initialize-CcodTrayWinForms
        switch($EventName){
            'Tick' {$handler=[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure();$Object.add_Tick($handler)}
            'Popup' {$handler=[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure();$Object.add_Popup($handler)}
            'Collapse' {$handler=[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure();$Object.add_Collapse($handler)}
            'Click' {$handler=[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure();$Object.add_Click($handler)}
            default {throw 'unsupported UI event'}
        }
        [pscustomobject][ordered]@{Target=$Object;EventName=$EventName;Handler=$handler}
    }
    $defaults.DetachUiCallback={
        param($Attachment)
        switch($Attachment.EventName){
            'Tick' {$Attachment.Target.remove_Tick($Attachment.Handler)}
            'Popup' {$Attachment.Target.remove_Popup($Attachment.Handler)}
            'Collapse' {$Attachment.Target.remove_Collapse($Attachment.Handler)}
            'Click' {$Attachment.Target.remove_Click($Attachment.Handler)}
            default {throw 'unsupported UI event'}
        }
    }
    $defaults.AddUiChild={
        param($Parent,$Child)
        Initialize-CcodTrayWinForms
        if($Child -isnot [Windows.Forms.MenuItem]){throw 'menu child is invalid'}
        if($Parent -is [Windows.Forms.ContextMenu] -or $Parent -is [Windows.Forms.MenuItem]){
            [void]$Parent.MenuItems.Add($Child)
            return
        }
        throw 'menu parent is invalid'
    }
    $defaults.DisposeUiObject={param($Object)Initialize-CcodTrayWinForms;if($Object -is [IDisposable]){$Object.Dispose()}}
    $defaults.ExitUiContext={param($Context)$Context.ExitThread()}
    $defaults.ShowErrorDialog={
        param($Title,$Message)
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [Windows.Forms.MessageBox]::Show($Message,$Title,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
    }
    $defaults.EndMenu={
        Initialize-CcodTrayNativeMethodsV3
        if(-not [CcodTrayNativeMethodsV3]::EndMenu()){throw 'EndMenu failed'}
    }
    $defaults.CreateBitmap={param($Color,$Size)Add-Type -AssemblyName System.Drawing -ErrorAction Stop;New-Object Drawing.Bitmap($Size,$Size)}
    $defaults.DrawBridgeIcon={
        param($Bitmap,$Color,$Size)
        $palette=@{
            Gray=[Drawing.Color]::FromArgb(255,138,144,153)
            Green=[Drawing.Color]::FromArgb(255,41,179,111)
            Yellow=[Drawing.Color]::FromArgb(255,227,160,8)
            Red=[Drawing.Color]::FromArgb(255,217,74,74)
        }
        $graphics=$null;$basePath=$null;$baseBrush=$null;$linkOnePath=$null;$linkTwoPath=$null;$linkPen=$null;$dotBrush=$null;$dotOutlinePen=$null
        try{
            $graphics=[Drawing.Graphics]::FromImage($Bitmap)
            $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.Clear([Drawing.Color]::Transparent)
            $scale=[single]($Size/32.0)

            $basePath=[Drawing.Drawing2D.GraphicsPath]::new()
            $baseX=[single](2*$scale);$baseY=[single](2*$scale);$baseWidth=[single](28*$scale);$baseHeight=[single](28*$scale);$baseCorner=[single](8*$scale)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX,$baseY,$baseCorner,$baseCorner),180,90)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX+$baseWidth-$baseCorner,$baseY,$baseCorner,$baseCorner),270,90)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX+$baseWidth-$baseCorner,$baseY+$baseHeight-$baseCorner,$baseCorner,$baseCorner),0,90)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX,$baseY+$baseHeight-$baseCorner,$baseCorner,$baseCorner),90,90)
            $basePath.CloseFigure()
            $baseBrush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255,32,37,45))
            $graphics.FillPath($baseBrush,$basePath)

            $linkOnePath=[Drawing.Drawing2D.GraphicsPath]::new()
            $linkOneX=[single](6.5*$scale);$linkOneY=[single](12.5*$scale);$linkWidth=[single](14*$scale);$linkHeight=[single](8.5*$scale)
            $linkOnePath.AddArc([Drawing.RectangleF]::new($linkOneX,$linkOneY,$linkHeight,$linkHeight),90,180)
            $linkOnePath.AddLine($linkOneX+($linkHeight/2),$linkOneY,$linkOneX+$linkWidth-($linkHeight/2),$linkOneY)
            $linkOnePath.AddArc([Drawing.RectangleF]::new($linkOneX+$linkWidth-$linkHeight,$linkOneY,$linkHeight,$linkHeight),270,180)
            $linkOnePath.AddLine($linkOneX+$linkWidth-($linkHeight/2),$linkOneY+$linkHeight,$linkOneX+($linkHeight/2),$linkOneY+$linkHeight)
            $linkOnePath.CloseFigure()

            $linkTwoPath=[Drawing.Drawing2D.GraphicsPath]::new()
            $linkTwoX=[single](11.5*$scale);$linkTwoY=[single](9*$scale)
            $linkTwoPath.AddArc([Drawing.RectangleF]::new($linkTwoX,$linkTwoY,$linkHeight,$linkHeight),90,180)
            $linkTwoPath.AddLine($linkTwoX+($linkHeight/2),$linkTwoY,$linkTwoX+$linkWidth-($linkHeight/2),$linkTwoY)
            $linkTwoPath.AddArc([Drawing.RectangleF]::new($linkTwoX+$linkWidth-$linkHeight,$linkTwoY,$linkHeight,$linkHeight),270,180)
            $linkTwoPath.AddLine($linkTwoX+$linkWidth-($linkHeight/2),$linkTwoY+$linkHeight,$linkTwoX+($linkHeight/2),$linkTwoY+$linkHeight)
            $linkTwoPath.CloseFigure()

            $linkPen=[Drawing.Pen]::new([Drawing.Color]::White,[single](2.4*$scale))
            $linkPen.LineJoin=[Drawing.Drawing2D.LineJoin]::Round
            $graphics.DrawPath($linkPen,$linkOnePath)
            $graphics.DrawPath($linkPen,$linkTwoPath)

            $dotBrush=[Drawing.SolidBrush]::new($palette[$Color])
            $dotOutlinePen=[Drawing.Pen]::new([Drawing.Color]::White,[single](1.0*$scale))
            $dotBounds=[Drawing.RectangleF]::new([single](22*$scale),[single](22*$scale),[single](7*$scale),[single](7*$scale))
            $graphics.FillEllipse($dotBrush,$dotBounds)
            $graphics.DrawEllipse($dotOutlinePen,$dotBounds)
        }finally{
            if($null -ne $dotOutlinePen){$dotOutlinePen.Dispose()}
            if($null -ne $dotBrush){$dotBrush.Dispose()}
            if($null -ne $linkPen){$linkPen.Dispose()}
            if($null -ne $linkTwoPath){$linkTwoPath.Dispose()}
            if($null -ne $linkOnePath){$linkOnePath.Dispose()}
            if($null -ne $baseBrush){$baseBrush.Dispose()}
            if($null -ne $basePath){$basePath.Dispose()}
            if($null -ne $graphics){$graphics.Dispose()}
        }
    }
    $defaults.GetHicon={param($Bitmap)$Bitmap.GetHicon()}
    $defaults.CloneIcon={
        param($Hicon,$Color,$Size)
        $temporary=$null
        try{
            $temporary=[Drawing.Icon]::FromHandle($Hicon)
            $temporary.Clone()
        }finally{
            if($null -ne $temporary){$temporary.Dispose()}
        }
    }
    $defaults.DestroyIcon={
        param($Hicon)
        Initialize-CcodTrayNativeMethodsV3
        if(-not [CcodTrayNativeMethodsV3]::DestroyIcon($Hicon)){throw 'DestroyIcon failed'}
    }
    $defaults.DisposeIconResource={param($Resource)$Resource.Dispose()}
    $defaults.NewSourceIdentifier={'ccod-process-'+[guid]::NewGuid().ToString('N')}
    $defaults.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $job=Register-WmiEvent -Class $ClassName -SourceIdentifier $SourceIdentifier -MessageData $Callback -Action {
            $processId=$Event.SourceEventArgs.NewEvent.ProcessID
            $name=$Event.SourceEventArgs.NewEvent.ProcessName
            & $Event.MessageData $processId $name
        }
        $jobId=[int]$job.Id
        $jobs=[Collections.Generic.Dictionary[int,bool]]::new();$jobs.Add($jobId,$true)
        $watcherAttemptJobs[$SourceIdentifier]=[pscustomobject]@{SubscriberPending=$true;Jobs=$jobs}
        [pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=$jobId;Resource=$job}
    }.GetNewClosure()
    $defaults.RegisterIntrinsic={
        param($SourceIdentifier,$Query,$Callback)
        $job=Register-WmiEvent -Query $Query -SourceIdentifier $SourceIdentifier -MessageData $Callback -Action {
            $processId=$Event.SourceEventArgs.NewEvent.TargetInstance.ProcessId
            $name=$Event.SourceEventArgs.NewEvent.TargetInstance.Name
            & $Event.MessageData $processId $name
        }
        $jobId=[int]$job.Id
        $jobs=[Collections.Generic.Dictionary[int,bool]]::new();$jobs.Add($jobId,$true)
        $watcherAttemptJobs[$SourceIdentifier]=[pscustomobject]@{SubscriberPending=$true;Jobs=$jobs}
        [pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=$jobId;Resource=$job}
    }.GetNewClosure()
    $defaults.CleanupWatcherAttempt={
        param($SourceIdentifier)
        try{
            $subscribers=@(Get-EventSubscriber -ErrorAction Stop|Where-Object {$_.SourceIdentifier -is [string] -and $_.SourceIdentifier -ceq $SourceIdentifier}|Select-Object -First ($watcherAttemptJobLimit+1))
        }catch{throw 'watcher attempt cleanup failed'}
        if($subscribers.Count -gt $watcherAttemptJobLimit){throw 'watcher attempt cleanup failed'}
        $discovered=[Collections.Generic.HashSet[int]]::new()
        foreach($subscriber in $subscribers){
            if($null -eq $subscriber.Action -or $subscriber.Action.Id -isnot [int] -or $subscriber.Action.Id -le 0 -or -not $discovered.Add([int]$subscriber.Action.Id)){
                if($null -eq $subscriber.Action -or $subscriber.Action.Id -isnot [int] -or $subscriber.Action.Id -le 0){throw 'watcher attempt cleanup failed'}
            }
        }
        $entry=if($watcherAttemptJobs.ContainsKey($SourceIdentifier)){$watcherAttemptJobs[$SourceIdentifier]}else{$null}
        if($null -eq $entry -and $subscribers.Count -eq 0){return}
        if($null -eq $entry){
            $entry=[pscustomobject]@{SubscriberPending=$false;Jobs=[Collections.Generic.Dictionary[int,bool]]::new()}
            $watcherAttemptJobs[$SourceIdentifier]=$entry
        }
        foreach($jobId in $discovered){
            if(-not $entry.Jobs.ContainsKey($jobId)){
                if($entry.Jobs.Count -ge $watcherAttemptJobLimit){throw 'watcher attempt cleanup failed'}
                $entry.Jobs.Add($jobId,$true)
            }else{$entry.Jobs[$jobId]=$true}
        }
        if($subscribers.Count -gt 0){$entry.SubscriberPending=$true}

        $failed=$false
        if($entry.SubscriberPending){
            if($subscribers.Count -gt 0){
                try{Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction Stop;$entry.SubscriberPending=$false}catch{$failed=$true}
            }else{$entry.SubscriberPending=$false}
        }
        if(-not $entry.SubscriberPending){
            foreach($jobId in @($entry.Jobs.Keys|Sort-Object)){
                if(-not $entry.Jobs[$jobId]){continue}
                try{$jobs=@(Get-Job -ErrorAction Stop|Where-Object {$_.Id -is [int] -and $_.Id -eq $jobId}|Select-Object -First 2)}catch{$failed=$true;continue}
                if($jobs.Count -eq 0){$entry.Jobs[$jobId]=$false;continue}
                if($jobs.Count -gt 1){$failed=$true;continue}
                try{Remove-Job -Id $jobId -Force -ErrorAction Stop;$entry.Jobs[$jobId]=$false}catch{$failed=$true}
            }
        }
        if($failed){throw 'watcher attempt cleanup failed'}
        $pendingJobs=@($entry.Jobs.Values|Where-Object {$_}).Count
        if(-not $entry.SubscriberPending -and $pendingJobs -eq 0){[void]$watcherAttemptJobs.Remove($SourceIdentifier)}
    }.GetNewClosure()
    $defaults.DetachWatcherCallback={param($Receipt)}
    $defaults.UnregisterWatcher={param($SourceIdentifier)Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction Stop}
    $defaults.RemoveWatcherJob={param($JobId)Remove-Job -Id $JobId -Force -ErrorAction Stop}
    $defaults.DisposeWatcherResource={param($Resource)if($Resource -is [IDisposable]){$Resource.Dispose()}}
    return $defaults
}

function Get-CcodTrayAdapters {
    param($Adapters,[string]$ErrorCode,[string]$Surface='Tray')
    if($null -ne $Adapters -and $Adapters -isnot [hashtable]){Throw-CcodTrayError $ErrorCode $Surface}
    $result=Get-CcodTrayDefaultAdapters
    if($null -ne $Adapters){
        foreach($name in $Adapters.Keys){
            if($name -isnot [string] -or $script:TrayAdapterNames -cnotcontains $name -or $Adapters[$name] -isnot [scriptblock]){Throw-CcodTrayError $ErrorCode $Surface}
            $result[$name]=$Adapters[$name]
        }
    }
    return $result
}

function Get-CcodCanonicalUtc {
    param($Adapters,[string]$FailureCode,[string]$Surface='Tray')
    $now=Invoke-CcodTrayAdapter $Adapters.GetUtcNow @() 1 $FailureCode $Surface
    if($now -isnot [DateTimeOffset] -or $now.Offset -ne [TimeSpan]::Zero){Throw-CcodTrayError $FailureCode $Surface}
    return $now.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function Test-CcodAdapterSet {
    param($Adapters)
    try{
        if($Adapters -isnot [hashtable] -or $Adapters.Count -ne $script:TrayAdapterNames.Count){return $false}
        foreach($key in @($Adapters.Keys)){
            if($key -isnot [string] -or $script:TrayAdapterNames -cnotcontains $key -or $Adapters[$key] -isnot [scriptblock]){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodOrderedKeys {
    param($Dictionary,[string[]]$Names)
    try{
        if($Dictionary -isnot [Collections.Specialized.OrderedDictionary] -or $Dictionary.Count -ne $Names.Count){return $false}
        $actual=@($Dictionary.Keys)
        for($index=0;$index -lt $Names.Count;$index++){if($actual[$index] -isnot [string] -or $actual[$index] -cne $Names[$index]){return $false}}
        return $true
    }catch{return $false}
}

function Test-CcodCleanupReceipt {
    param($Receipt,[ValidateSet('Closed','Stopped')][string]$Terminal,[string[]]$Allowlist)
    try{
        if($null -eq $Receipt){return $true}
        if(-not (Test-CcodExactProperties $Receipt @('SchemaVersion',$Terminal,'CleanupCodes')) -or
           $Receipt.SchemaVersion -isnot [int] -or $Receipt.SchemaVersion -ne 1 -or $Receipt.$Terminal -isnot [bool] -or -not $Receipt.$Terminal -or
           $Receipt.CleanupCodes -isnot [array]){return $false}
        $codes=@($Receipt.CleanupCodes)
        if($codes.Count -gt 16){return $false}
        foreach($code in $codes){if($code -isnot [string] -or $Allowlist -cnotcontains $code){return $false}}
        return $true
    }catch{return $false}
}

function Test-CcodContextObject {
    param($Context)
    try{
        $names=@(
            'SchemaVersion','State','OwnerManagedThreadId','CommandQueue','CommandOverflowed','CallbackFailure','QueueGate','CloseGate','OnTick','Adapters',
            'MenuOpen','PendingRender','CurrentRender','LastAppliedFingerprint',
            'ApplicationContext','Timer','NotifyIcon','Menu','Items','LanguageItems','Separators','Icons','Callbacks','CommandValues','CleanupCodes','CloseReceipt'
        )
        if(-not (Test-CcodExactProperties $Context $names) -or $Context.PSObject.TypeNames -cnotcontains 'Ccod.TrayContext'){return $false}
        if($Context.SchemaVersion -isnot [int] -or $Context.SchemaVersion -ne 1 -or $Context.State -isnot [string] -or
           @('Creating','Open','Closing','Closed') -cnotcontains $Context.State -or $Context.OwnerManagedThreadId -isnot [int] -or $Context.OwnerManagedThreadId -le 0 -or
           $null -eq $Context.CommandQueue -or $Context.CommandOverflowed -isnot [bool] -or $Context.CallbackFailure -isnot [bool] -or
            $null -eq $Context.QueueGate -or $Context.QueueGate.GetType() -ne [object] -or $null -eq $Context.CloseGate -or $Context.CloseGate.GetType() -ne [object] -or
            $Context.MenuOpen -isnot [bool] -or
            ($null -ne $Context.LastAppliedFingerprint -and ($Context.LastAppliedFingerprint -isnot [string] -or $Context.LastAppliedFingerprint -cnotmatch '^[0-9a-f]{64}$')) -or
            -not (Test-CcodTrayRenderState $Context.PendingRender) -or
            -not (Test-CcodTrayRenderState $Context.CurrentRender) -or
            -not (Test-CcodAdapterSet $Context.Adapters) -or $Context.Items -isnot [Collections.Specialized.OrderedDictionary] -or $Context.LanguageItems -isnot [Collections.Specialized.OrderedDictionary] -or $Context.Separators -isnot [Collections.Specialized.OrderedDictionary] -or $Context.Icons -isnot [Collections.Specialized.OrderedDictionary] -or $Context.Callbacks -isnot [Collections.Generic.List[object]] -or
           $Context.CleanupCodes -isnot [Collections.Generic.List[string]] -or
            -not (Test-CcodOrderedKeys $Context.CommandValues @('AutomationChecked','CandidateOptInChecked','LanguageMode')) -or
            $Context.CommandValues.AutomationChecked -isnot [bool] -or $Context.CommandValues.CandidateOptInChecked -isnot [bool] -or
            $Context.CommandValues.LanguageMode -isnot [string] -or $script:TrayUiLanguageModes -cnotcontains $Context.CommandValues.LanguageMode -or
           -not (Test-CcodCleanupReceipt $Context.CloseReceipt 'Closed' $script:TrayCleanupCodeAllowlist)){return $false}
        if($Context.State -ceq 'Closed'){
            if($null -ne $Context.OnTick -or $null -eq $Context.CloseReceipt -or $Context.MenuOpen -or $null -ne $Context.PendingRender){return $false}
        }elseif($Context.State -ceq 'Closing'){
            if(($null -ne $Context.OnTick -and $Context.OnTick -isnot [scriptblock]) -or $null -eq $Context.CloseReceipt -or $Context.MenuOpen -or $null -ne $Context.PendingRender){return $false}
        }elseif($Context.OnTick -isnot [scriptblock] -or $null -ne $Context.CloseReceipt){return $false}
        if($Context.State -cne 'Creating'){
            if($null -eq $Context.ApplicationContext -or $null -eq $Context.Timer -or $null -eq $Context.NotifyIcon -or $null -eq $Context.Menu -or $null -eq $Context.CurrentRender -or
               -not (Test-CcodOrderedKeys $Context.Icons @('Gray:16','Gray:32','Green:16','Green:32','Yellow:16','Yellow:32','Red:16','Red:32'))){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodWatcherObject {
    param($Watcher)
    try{
        $names=@(
            'SchemaVersion','State','Mode','Queue','OnFullReconciliationRequired','QueueGate','StopGate','FullReconciliationNeeded','OverflowEpisodeSignaled',
            'CallbackFailure','Registration','Callback','Adapters','PendingAttemptSources','CapabilityCleanupFailed','CleanupCodes','StopReceipt'
        )
        if(-not (Test-CcodExactProperties $Watcher $names) -or $Watcher.PSObject.TypeNames -cnotcontains 'Ccod.ProcessWatcher'){return $false}
        if($Watcher.SchemaVersion -isnot [int] -or $Watcher.SchemaVersion -ne 1 -or $Watcher.State -isnot [string] -or
           @('Starting','Running','Stopping','Stopped') -cnotcontains $Watcher.State -or $Watcher.Mode -isnot [string] -or
           @('ReconciliationOnly','Trace','Intrinsic') -cnotcontains $Watcher.Mode -or $null -eq $Watcher.Queue -or
           $null -eq $Watcher.QueueGate -or $Watcher.QueueGate.GetType() -ne [object] -or $null -eq $Watcher.StopGate -or $Watcher.StopGate.GetType() -ne [object] -or
           $Watcher.FullReconciliationNeeded -isnot [bool] -or $Watcher.OverflowEpisodeSignaled -isnot [bool] -or $Watcher.CallbackFailure -isnot [bool] -or
           -not (Test-CcodAdapterSet $Watcher.Adapters) -or $Watcher.PendingAttemptSources -isnot [Collections.Generic.List[string]] -or
           $Watcher.PendingAttemptSources.Count -gt 2 -or $Watcher.CapabilityCleanupFailed -isnot [bool] -or
           $Watcher.CleanupCodes -isnot [Collections.Generic.List[string]] -or
           -not (Test-CcodCleanupReceipt $Watcher.StopReceipt 'Stopped' $script:WatcherCleanupCodeAllowlist)){return $false}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($source in $Watcher.PendingAttemptSources){if($source -isnot [string] -or $source -cnotmatch '^ccod-process-[0-9a-f]{32}$' -or -not $seen.Add($source)){return $false}}
        if($null -ne $Watcher.Registration){
            if(-not (Test-CcodExactProperties $Watcher.Registration @('SourceIdentifier','JobId','Resource')) -or
               $Watcher.Registration.SourceIdentifier -isnot [string] -or $Watcher.Registration.SourceIdentifier -cnotmatch '^ccod-process-[0-9a-f]{32}$' -or
               $Watcher.Registration.JobId -isnot [int] -or $Watcher.Registration.JobId -le 0 -or $null -eq $Watcher.Registration.Resource){return $false}
        }
        if($Watcher.State -ceq 'Stopped'){
            if($null -ne $Watcher.Callback -or $null -ne $Watcher.OnFullReconciliationRequired -or $null -eq $Watcher.StopReceipt){return $false}
        }elseif($Watcher.State -ceq 'Stopping'){
            if(($null -ne $Watcher.Callback -and $Watcher.Callback -isnot [scriptblock]) -or
               ($null -ne $Watcher.OnFullReconciliationRequired -and $Watcher.OnFullReconciliationRequired -isnot [scriptblock]) -or
               $null -eq $Watcher.StopReceipt){return $false}
        }elseif($Watcher.Callback -isnot [scriptblock] -or $Watcher.OnFullReconciliationRequired -isnot [scriptblock] -or $null -ne $Watcher.StopReceipt){return $false}
        return $true
    }catch{return $false}
}

function Test-CcodContextGateHandle {
    param($Context)
    try{
        $names=@(
            'SchemaVersion','State','OwnerManagedThreadId','CommandQueue','CommandOverflowed','CallbackFailure','QueueGate','CloseGate','OnTick','Adapters',
            'MenuOpen','PendingRender','CurrentRender','LastAppliedFingerprint',
            'ApplicationContext','Timer','NotifyIcon','Menu','Items','LanguageItems','Separators','Icons','Callbacks','CommandValues','CleanupCodes','CloseReceipt'
        )
        return (Test-CcodExactProperties $Context $names) -and $Context.PSObject.TypeNames -ccontains 'Ccod.TrayContext' -and
            $null -ne $Context.CloseGate -and $Context.CloseGate.GetType() -eq [object]
    }catch{return $false}
}

function Test-CcodWatcherGateHandle {
    param($Watcher)
    try{
        $names=@(
            'SchemaVersion','State','Mode','Queue','OnFullReconciliationRequired','QueueGate','StopGate','FullReconciliationNeeded','OverflowEpisodeSignaled',
            'CallbackFailure','Registration','Callback','Adapters','PendingAttemptSources','CapabilityCleanupFailed','CleanupCodes','StopReceipt'
        )
        return (Test-CcodExactProperties $Watcher $names) -and $Watcher.PSObject.TypeNames -ccontains 'Ccod.ProcessWatcher' -and
            $null -ne $Watcher.StopGate -and $Watcher.StopGate.GetType() -eq [object]
    }catch{return $false}
}

function Add-CcodCleanupCode {
    param([Collections.Generic.List[string]]$Codes,[string]$Code)
    if(-not $Codes.Contains($Code) -and $Codes.Count -lt 16){$Codes.Add($Code)}
}

function Invoke-CcodCleanupStage {
    param([scriptblock]$Action,[Collections.Generic.List[string]]$Codes,[string]$Code,[string]$Surface='Tray')
    try{& $Action}catch{Add-CcodCleanupCode $Codes $Code}
}

function Find-CcodTrayNativeMenuCommand {
    param([object[]]$Items,[int]$CommandId)
    foreach($item in @($Items)){
        if(-not (Test-CcodExactProperties $item @('CommandId','Text','Enabled','Checked','Radio','Separator','Children'))){continue}
        if(-not $item.Separator -and $item.CommandId -is [int] -and $item.CommandId -eq $CommandId){return $item}
        if($item.Children -is [array] -and $item.Children.Count -gt 0){
            $nested=Find-CcodTrayNativeMenuCommand -Items $item.Children -CommandId $CommandId
            if($null -ne $nested){return $nested}
        }
    }
    return $null
}

function Invoke-CcodTrayNativeCommandId {
    param($Context,[object[]]$Items,[int]$CommandId)
    [Threading.Monitor]::Enter($Context.QueueGate)
    try{
        if($Context.State -cne 'Open'){return}
        $item=Find-CcodTrayNativeMenuCommand -Items $Items -CommandId $CommandId
        if($null -eq $item -or $item.Enabled -isnot [bool] -or -not $item.Enabled){return}
        $kind=$null;$value=$null
        switch($CommandId){
            1001 {$kind='ApplyNow'}
            1002 {$kind='ManualRetry'}
            1003 {$kind='SetAutomationEnabled';$value=[bool](-not $Context.CommandValues.AutomationChecked)}
            1004 {$kind='SetCandidateCompatibleOptIn';$value=[bool](-not $Context.CommandValues.CandidateOptInChecked)}
            1005 {$kind='SetUiLanguage';$value='System'}
            1006 {$kind='SetUiLanguage';$value='zh-CN'}
            1007 {$kind='SetUiLanguage';$value='en-US'}
            1008 {$kind='OpenLogs'}
            default {return}
        }
        $timestamp=Get-CcodCanonicalUtc $Context.Adapters 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $command=[pscustomobject][ordered]@{Kind=$kind;Value=$value;EnqueuedAtUtc=$timestamp}
        $queueArgument=[object[]]::new(1);$queueArgument[0]=$Context.CommandQueue
        $count=Invoke-CcodTrayAdapter $Context.Adapters.GetQueueCount $queueArgument 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        if($count -isnot [int] -or $count -lt 0){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
        if($count -ge 256){$Context.CommandOverflowed=$true;return}
        $enqueueArguments=[object[]]::new(2);$enqueueArguments[0]=$Context.CommandQueue;$enqueueArguments[1]=$command
        $added=Invoke-CcodTrayAdapter $Context.Adapters.TryEnqueue $enqueueArguments 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        if($added -isnot [bool] -or -not $added){$Context.CommandOverflowed=$true}
    }catch{if($Context.State -ceq 'Open'){$Context.CallbackFailure=$true}}
    finally{[Threading.Monitor]::Exit($Context.QueueGate)}
}

function Get-CcodTrayPresentationFingerprint {
    param($Presentation,$Localized,[string]$LanguageMode,[string]$SystemCultureName)
    $builder=[Text.StringBuilder]::new()
    foreach($value in @($LanguageMode,$SystemCultureName)){
        $text=[string]$value;[void]$builder.Append($text.Length).Append(':').Append($text).Append(';')
    }
    foreach($property in $Presentation.PSObject.Properties){
        $text=('{0}={1}' -f $property.Name,[string]$property.Value);[void]$builder.Append($text.Length).Append(':').Append($text).Append(';')
    }
    foreach($key in $script:TrayUiCatalogKeys){
        $text=('{0}={1}' -f $key,[string]$Localized[$key]);[void]$builder.Append($text.Length).Append(':').Append($text).Append(';')
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes($builder.ToString())
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
}

function New-CcodTrayRenderState {
    param($Presentation,$Localized,[string]$LanguageMode,[string]$SystemCultureName)
    $snapshot=[pscustomobject][ordered]@{}
    foreach($property in $Presentation.PSObject.Properties){$snapshot|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value}
    $strings=[ordered]@{}
    foreach($key in $script:TrayUiCatalogKeys){$strings[$key]=[string]$Localized[$key]}
    [pscustomobject][ordered]@{
        Presentation=$snapshot;Localized=$strings;LanguageMode=$LanguageMode;SystemCultureName=$SystemCultureName
        Fingerprint=(Get-CcodTrayPresentationFingerprint $snapshot $strings $LanguageMode $SystemCultureName)
    }
}

function Test-CcodTrayRenderState {
    param($Render)
    if($null -eq $Render){return $true}
    try{
        if(-not (Test-CcodExactProperties $Render @('Presentation','Localized','LanguageMode','SystemCultureName','Fingerprint')) -or
           $Render.LanguageMode -isnot [string] -or $script:TrayUiLanguageModes -cnotcontains $Render.LanguageMode -or
           $Render.SystemCultureName -isnot [string] -or $Render.SystemCultureName.Length -lt 1 -or $Render.SystemCultureName.Length -gt 85 -or
           (Test-CcodControlCharacter $Render.SystemCultureName) -or $Render.Fingerprint -isnot [string] -or $Render.Fingerprint -cnotmatch '^[0-9a-f]{64}$' -or
           -not (Test-CcodOrderedKeys $Render.Localized $script:TrayUiCatalogKeys)){return $false}
        Assert-CcodTrayPresentation $Render.Presentation
        foreach($key in $script:TrayUiCatalogKeys){
            $value=$Render.Localized[$key]
            if($value -isnot [string] -or $value.Length -lt 1 -or $value.Length -gt 300 -or (Test-CcodControlCharacter $value)){return $false}
        }
        return $true
    }catch{return $false}
}

function New-CcodTrayNativeMenuItem {
    param(
        [int]$CommandId,[string]$Text,[bool]$Enabled=$false,[bool]$Checked=$false,[bool]$Radio=$false,
        [bool]$Separator=$false,[object[]]$Children=@()
    )
    [pscustomobject][ordered]@{
        CommandId=$CommandId;Text=$Text;Enabled=$Enabled;Checked=$Checked;Radio=$Radio;Separator=$Separator;Children=[object[]]@($Children)
    }
}

function New-CcodTrayNativeMenuSpec {
    param($Render)
    if(-not (Test-CcodTrayRenderState $Render) -or $null -eq $Render){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
    $presentation=$Render.Presentation;$strings=$Render.Localized
    $items=[Collections.Generic.List[object]]::new()
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 0 -Text $strings['Tray.Title']))
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 0 -Text $strings['Status.'+$presentation.StateKey]))
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 0 -Text '' -Separator $true))
    if($presentation.SessionReadyVisible){$items.Add((New-CcodTrayNativeMenuItem -CommandId 0 -Text $strings['Menu.SessionReady']))}
    if($presentation.ApplyNowVisible){$items.Add((New-CcodTrayNativeMenuItem -CommandId 1001 -Text $strings['Menu.ApplyNow'] -Enabled $presentation.ApplyNowEnabled))}
    if($presentation.ManualRetryVisible){$items.Add((New-CcodTrayNativeMenuItem -CommandId 1002 -Text $strings['Menu.ManualRetry'] -Enabled $presentation.ManualRetryEnabled))}
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 0 -Text '' -Separator $true))
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 1003 -Text $strings['Menu.Automation'] -Enabled $presentation.AutomationToggleEnabled -Checked $presentation.AutomationChecked))
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 1004 -Text $strings['Menu.CandidateOptIn'] -Enabled $presentation.CandidateOptInToggleEnabled -Checked $presentation.CandidateOptInChecked))
    $languageItems=@(
        New-CcodTrayNativeMenuItem -CommandId 1005 -Text $strings['Menu.FollowSystem'] -Enabled $true -Checked ($Render.LanguageMode -ceq 'System') -Radio $true
        New-CcodTrayNativeMenuItem -CommandId 1006 -Text $strings['Menu.Chinese'] -Enabled $true -Checked ($Render.LanguageMode -ceq 'zh-CN') -Radio $true
        New-CcodTrayNativeMenuItem -CommandId 1007 -Text $strings['Menu.English'] -Enabled $true -Checked ($Render.LanguageMode -ceq 'en-US') -Radio $true
    )
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 0 -Text $strings['Menu.Language'] -Enabled $true -Children $languageItems))
    $items.Add((New-CcodTrayNativeMenuItem -CommandId 1008 -Text $strings['Menu.OpenLogs'] -Enabled $presentation.OpenLogsEnabled))
    Write-Output -NoEnumerate ([object[]]$items.ToArray())
}

function New-CcodTrayMenuItem {
    param($Context,[string]$Key,$Parent,[string]$Text='')
    $nonnull={param($value)[bool]($null -ne $value)}
    $item=Invoke-CcodOwnedTrayAdapter $Context.Adapters.CreateUiObject @('MenuItem','TrayMenu'+$Key) $Context.Adapters.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
    Invoke-CcodTrayAdapter $Context.Adapters.SetUiProperty @($item,'Text',$Text) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
    Invoke-CcodTrayAdapter $Context.Adapters.AddUiChild @($Parent,$item) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
    return $item
}

function Set-CcodTrayMenuItem {
    param($Context,$Item,[string]$Text,[bool]$Enabled,[bool]$Visible=$true,[bool]$Checked=$false,[bool]$Radio=$false)
    $adapter=$Context.Adapters
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Item,'Text',$Text) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Item,'Enabled',$Enabled) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Item,'Visible',$Visible) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Item,'Checked',$Checked) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Item,'RadioCheck',$Radio) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
}

function Update-CcodTrayContextMenu {
    param($Context,$Render)
    $presentation=$Render.Presentation;$strings=$Render.Localized;$items=$Context.Items;$language=$Context.LanguageItems
    Set-CcodTrayMenuItem $Context $items.Title $strings['Tray.Title'] $false $true
    Set-CcodTrayMenuItem $Context $items.Status $strings['Status.'+$presentation.StateKey] $false $true
    Set-CcodTrayMenuItem $Context $items.SessionReady $strings['Menu.SessionReady'] $false $presentation.SessionReadyVisible
    Set-CcodTrayMenuItem $Context $items.ApplyNow $strings['Menu.ApplyNow'] $presentation.ApplyNowEnabled $presentation.ApplyNowVisible
    Set-CcodTrayMenuItem $Context $items.ManualRetry $strings['Menu.ManualRetry'] $presentation.ManualRetryEnabled $presentation.ManualRetryVisible
    Set-CcodTrayMenuItem $Context $items.Automation $strings['Menu.Automation'] $presentation.AutomationToggleEnabled $true $presentation.AutomationChecked
    Set-CcodTrayMenuItem $Context $items.CandidateOptIn $strings['Menu.CandidateOptIn'] $presentation.CandidateOptInToggleEnabled $true $presentation.CandidateOptInChecked
    Set-CcodTrayMenuItem $Context $items.Language $strings['Menu.Language'] $true $true
    Set-CcodTrayMenuItem $Context $language.System $strings['Menu.FollowSystem'] $true $true ($Render.LanguageMode -ceq 'System') $true
    Set-CcodTrayMenuItem $Context $language.Chinese $strings['Menu.Chinese'] $true $true ($Render.LanguageMode -ceq 'zh-CN') $true
    Set-CcodTrayMenuItem $Context $language.English $strings['Menu.English'] $true $true ($Render.LanguageMode -ceq 'en-US') $true
    Set-CcodTrayMenuItem $Context $items.OpenLogs $strings['Menu.OpenLogs'] $presentation.OpenLogsEnabled $true
    foreach($separator in @($Context.Separators.Values)){
        Set-CcodTrayMenuItem $Context $separator '-' $false $true
    }
}

function Invoke-CcodTrayRenderWrite {
    param($Context,$Render,[string]$FailureCode)
    if($Render.Fingerprint -ceq $Context.LastAppliedFingerprint){return}
    $presentation=$Render.Presentation;$adapter=$Context.Adapters
    $tooltipStateKey=if($presentation.StateKey -ceq 'RendererHandoff'){'Active'}else{$presentation.StateKey}
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.NotifyIcon,'Text',$Render.Localized['Tooltip.'+$tooltipStateKey]) 0 $FailureCode 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.NotifyIcon,'Icon',$Context.Icons[$presentation.Color+':16']) 0 $FailureCode 'Tray'
    Update-CcodTrayContextMenu $Context $Render
    $Context.CommandValues.AutomationChecked=[bool]$presentation.AutomationChecked
    $Context.CommandValues.CandidateOptInChecked=[bool]$presentation.CandidateOptInChecked
    $Context.CommandValues.LanguageMode=$Render.LanguageMode
    $Context.CurrentRender=$Render
    $Context.LastAppliedFingerprint=$Render.Fingerprint
}

function New-CcodTrayContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$CommandQueue,[Parameter(Mandatory)][AllowNull()]$OnTick,
        [Parameter(Mandatory)][AllowNull()]$Catalog,[Parameter(Mandatory)][AllowNull()]$LanguageMode,
        [Parameter(Mandatory)][AllowNull()]$SystemCultureName,[AllowNull()]$Adapters
    )
    if($null -eq $CommandQueue -or $OnTick -isnot [scriptblock]){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $adapter=Get-CcodTrayAdapters $Adapters 'CCOD_TRAY_INPUT_INVALID' 'Tray'
    try{
        $threadId=Invoke-CcodTrayAdapter $adapter.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
        $apartment=Invoke-CcodTrayAdapter $adapter.GetApartmentState @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
    }catch{Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
    if($threadId -isnot [int] -or $threadId -le 0 -or $apartment -isnot [string] -or $apartment -cne 'STA'){Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$CommandQueue
    $initialCount=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_TRAY_INPUT_INVALID' 'Tray'
    if($initialCount -isnot [int] -or $initialCount -lt 0 -or $initialCount -gt 256){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $localized=Resolve-CcodTrayLocalizedStrings $Catalog $LanguageMode $SystemCultureName
    $context=[pscustomobject][ordered]@{
        SchemaVersion=1;State='Creating';OwnerManagedThreadId=$threadId;CommandQueue=$CommandQueue
        CommandOverflowed=$false;CallbackFailure=$false;QueueGate=New-Object object;CloseGate=New-Object object;OnTick=$OnTick;Adapters=$adapter
        MenuOpen=$false;PendingRender=$null;CurrentRender=$null;LastAppliedFingerprint=$null
        ApplicationContext=$null;Timer=$null;NotifyIcon=$null;Menu=$null;Items=[ordered]@{};LanguageItems=[ordered]@{};Separators=[ordered]@{};Icons=[ordered]@{}
        Callbacks=[Collections.Generic.List[object]]::new();CommandValues=[ordered]@{
            AutomationChecked=$false;CandidateOptInChecked=$false
            LanguageMode=$LanguageMode
        }
        CleanupCodes=[Collections.Generic.List[string]]::new();CloseReceipt=$null
    }
    $context.PSObject.TypeNames.Insert(0,'Ccod.TrayContext')
    try{
        $nonnull={param($value)[bool]($null -ne $value)}
        $context.ApplicationContext=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('ApplicationContext','TrayApplicationContext') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Timer=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('Timer','TrayTimer') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.NotifyIcon=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('NotifyIcon','TrayNotifyIcon') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Menu=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('ContextMenu','TrayContextMenu') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Items['Title']=New-CcodTrayMenuItem $context 'Title' $context.Menu
        $context.Items['Status']=New-CcodTrayMenuItem $context 'Status' $context.Menu
        $context.Separators['BeforeActions']=New-CcodTrayMenuItem $context 'BeforeActions' $context.Menu '-'
        $context.Items['SessionReady']=New-CcodTrayMenuItem $context 'SessionReady' $context.Menu
        $context.Items['ApplyNow']=New-CcodTrayMenuItem $context 'ApplyNow' $context.Menu
        $context.Items['ManualRetry']=New-CcodTrayMenuItem $context 'ManualRetry' $context.Menu
        $context.Separators['BeforeToggles']=New-CcodTrayMenuItem $context 'BeforeToggles' $context.Menu '-'
        $context.Items['Automation']=New-CcodTrayMenuItem $context 'Automation' $context.Menu
        $context.Items['CandidateOptIn']=New-CcodTrayMenuItem $context 'CandidateOptIn' $context.Menu
        $context.Items['Language']=New-CcodTrayMenuItem $context 'Language' $context.Menu
        $context.LanguageItems['System']=New-CcodTrayMenuItem $context 'LanguageSystem' $context.Items['Language']
        $context.LanguageItems['Chinese']=New-CcodTrayMenuItem $context 'LanguageChinese' $context.Items['Language']
        $context.LanguageItems['English']=New-CcodTrayMenuItem $context 'LanguageEnglish' $context.Items['Language']
        $context.Items['OpenLogs']=New-CcodTrayMenuItem $context 'OpenLogs' $context.Menu
        foreach($color in @('Gray','Green','Yellow','Red')){
            foreach($size in @(16,32)){
                $bitmap=$null;$hicon=[IntPtr]::Zero
                try{
                    $bitmap=Invoke-CcodOwnedTrayAdapter $adapter.CreateBitmap @($color,[int]$size) $adapter.DisposeIconResource $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    Invoke-CcodTrayAdapter $adapter.DrawBridgeIcon @($bitmap,$color,[int]$size) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    $validHicon={param($value)[bool]($value -is [IntPtr] -and $value -ne [IntPtr]::Zero)}
                    $hicon=Invoke-CcodOwnedTrayAdapter $adapter.GetHicon @($bitmap) $adapter.DestroyIcon $validHicon 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    $clone=Invoke-CcodOwnedTrayAdapter $adapter.CloneIcon @($hicon,$color,[int]$size) $adapter.DisposeIconResource $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    $context.Icons[$color+':'+$size]=$clone
                }finally{
                    $iconCleanupFailed=$false
                    if($hicon -ne [IntPtr]::Zero){try{Invoke-CcodTrayAdapter $adapter.DestroyIcon @($hicon) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'}catch{$iconCleanupFailed=$true}}
                    if($null -ne $bitmap){try{Invoke-CcodTrayAdapter $adapter.DisposeIconResource @($bitmap) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'}catch{$iconCleanupFailed=$true}}
                    # Temporary GDI cleanup must not abort tray creation after a successful clone.
                    if($iconCleanupFailed -and -not $context.Icons.Contains($color+':'+$size)){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
                }
            }
        }
        $initialPresentation=[pscustomobject][ordered]@{
            Color='Gray';StateKey='Waiting';SessionReadyVisible=$false;ApplyNowVisible=$false;ApplyNowEnabled=$false;ManualRetryVisible=$false;ManualRetryEnabled=$false
            AutomationToggleEnabled=$false;AutomationChecked=$false;CandidateOptInToggleEnabled=$false;CandidateOptInChecked=$false;OpenLogsEnabled=$false;Busy=$false
        }
        $initialRender=New-CcodTrayRenderState $initialPresentation $localized $LanguageMode $SystemCultureName
        Invoke-CcodTrayRenderWrite $context $initialRender 'CCOD_TRAY_CREATE_FAILED'
        $contextRef=$context;$invokeAdapterRef=${function:Invoke-CcodTrayAdapter};$invokeRenderWriteRef=${function:Invoke-CcodTrayRenderWrite}
        $newNativeMenuSpecRef=${function:New-CcodTrayNativeMenuSpec};$invokeNativeCommandRef=${function:Invoke-CcodTrayNativeCommandId}
        $popup={
            param($sender,$eventArgs)
            [Threading.Monitor]::Enter($contextRef.QueueGate)
            try{
                if($contextRef.State -cne 'Open'){return}
                $current=& $invokeAdapterRef $contextRef.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
                if($current -isnot [int] -or $current -ne $contextRef.OwnerManagedThreadId){throw 'ContextMenu Popup thread is invalid'}
                $contextRef.MenuOpen=$true
            }catch{if($contextRef.State -ceq 'Open'){$contextRef.CallbackFailure=$true}}
            finally{[Threading.Monitor]::Exit($contextRef.QueueGate)}
        }.GetNewClosure()
        $collapse={
            param($sender,$eventArgs)
            [Threading.Monitor]::Enter($contextRef.QueueGate)
            try{
                if($contextRef.State -cne 'Open'){return}
                $current=& $invokeAdapterRef $contextRef.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
                if($current -isnot [int] -or $current -ne $contextRef.OwnerManagedThreadId){throw 'ContextMenu Collapse thread is invalid'}
                $contextRef.MenuOpen=$false
                $pending=$contextRef.PendingRender
                try{
                    if($null -ne $pending -and $pending.Fingerprint -cne $contextRef.LastAppliedFingerprint){& $invokeRenderWriteRef $contextRef $pending 'CCOD_TRAY_PRESENTATION_FAILED'}
                }finally{$contextRef.PendingRender=$null}
            }catch{if($contextRef.State -ceq 'Open'){$contextRef.CallbackFailure=$true}}
            finally{[Threading.Monitor]::Exit($contextRef.QueueGate)}
        }.GetNewClosure()
        $validMenuAttachment={param($value)[bool]((Test-CcodExactProperties $value @('Target','EventName','Handler')) -and $null -ne $value.Target -and $value.EventName -in @('Popup','Collapse','Click') -and $null -ne $value.Handler)}
        foreach($binding in @(@('Popup',$popup),@('Collapse',$collapse))){
            $attachment=Invoke-CcodOwnedTrayAdapter $adapter.AttachUiCallback @($context.Menu,$binding[0],$binding[1]) $adapter.DetachUiCallback $validMenuAttachment 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.Callbacks.Add($attachment)
        }
        $commandMap=[ordered]@{ApplyNow=1001;ManualRetry=1002;Automation=1003;CandidateOptIn=1004;System=1005;Chinese=1006;English=1007;OpenLogs=1008}
        foreach($key in @($commandMap.Keys)){
            $commandId=[int]$commandMap[$key]
            $click={
                param($sender,$eventArgs)
                $render=$null
                [Threading.Monitor]::Enter($contextRef.QueueGate)
                try{
                    if($contextRef.State -cne 'Open'){return}
                    $current=& $invokeAdapterRef $contextRef.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
                    if($current -isnot [int] -or $current -ne $contextRef.OwnerManagedThreadId){throw 'ContextMenu Click thread is invalid'}
                    $render=$contextRef.CurrentRender
                }catch{if($contextRef.State -ceq 'Open'){$contextRef.CallbackFailure=$true}}
                finally{[Threading.Monitor]::Exit($contextRef.QueueGate)}
                if($null -ne $render){$items=& $newNativeMenuSpecRef $render;& $invokeNativeCommandRef $contextRef $items $commandId}
            }.GetNewClosure()
            $target=if($key -in @('System','Chinese','English')){$context.LanguageItems[$key]}else{$context.Items[$key]}
            $attachment=Invoke-CcodOwnedTrayAdapter $adapter.AttachUiCallback @($target,'Click',$click) $adapter.DetachUiCallback $validMenuAttachment 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.Callbacks.Add($attachment)
        }
        $context.Callbacks.Add($attachment)
        $tick={
            param($sender,$eventArgs)
            $shouldRun=$false;$menuOpenOnly=$false;$onTick=$null
            [Threading.Monitor]::Enter($contextRef.QueueGate)
            try{
                if($contextRef.State -cne 'Open'){return}
                $current=& $invokeAdapterRef $contextRef.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
                if($current -isnot [int] -or $current -ne $contextRef.OwnerManagedThreadId){return}
                $menuOpenOnly=[bool]$contextRef.MenuOpen;$onTick=$contextRef.OnTick;$shouldRun=$true
            }catch{if($contextRef.State -ceq 'Open'){$contextRef.CallbackFailure=$true}}
            finally{[Threading.Monitor]::Exit($contextRef.QueueGate)}
            if(-not $shouldRun -or $onTick -isnot [scriptblock]){return}
            try{& $invokeAdapterRef $onTick @($menuOpenOnly) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
            catch{
                [Threading.Monitor]::Enter($contextRef.QueueGate)
                try{if($contextRef.State -ceq 'Open'){$contextRef.CallbackFailure=$true}}finally{[Threading.Monitor]::Exit($contextRef.QueueGate)}
            }
        }.GetNewClosure()
        $validTickAttachment={param($value)[bool]((Test-CcodExactProperties $value @('Target','EventName','Handler')) -and $null -ne $value.Target -and $value.EventName -ceq 'Tick' -and $null -ne $value.Handler)}
        $attachment=Invoke-CcodOwnedTrayAdapter $adapter.AttachUiCallback @($context.Timer,'Tick',$tick) $adapter.DetachUiCallback $validTickAttachment 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Callbacks.Add($attachment)
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.Timer,'Interval',[int]250) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.NotifyIcon,'ContextMenu',$context.Menu) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.NotifyIcon,'Icon',$context.Icons['Gray:16']) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.StartUiTimer @($context.Timer) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($context.NotifyIcon,$true) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        [Threading.Monitor]::Enter($context.QueueGate)
        try{$context.State='Open'}finally{[Threading.Monitor]::Exit($context.QueueGate)}
        return $context
    }catch{
        $createError = $_
        try{Close-CcodTrayContext -Context $context|Out-Null}catch{}
        if ($createError.FullyQualifiedErrorId -and ($createError.FullyQualifiedErrorId -split ',')[0] -cmatch '^CCOD_') {
            throw $createError
        }
        Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'
    }
}

function Close-CcodTrayContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Context)
    if(-not (Test-CcodContextGateHandle $Context)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $closeGate=$Context.CloseGate
    try{[Threading.Monitor]::Enter($closeGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
    if(-not (Test-CcodContextObject $Context)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    if($Context.State -ceq 'Closed'){return $Context.CloseReceipt}
    if($Context.State -ceq 'Closing'){return $Context.CloseReceipt}
    $queueGate=$Context.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $wasMenuOpen=$false
    try{
        $wasMenuOpen=[bool]$Context.MenuOpen
        $Context.State='Closing'
        $Context.MenuOpen=$false;$Context.PendingRender=$null
        $Context.CloseReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=@()}
    }finally{[Threading.Monitor]::Exit($queueGate)}
    $codes=[Collections.Generic.List[string]]::new();$Context.CleanupCodes=$codes;$adapter=$Context.Adapters
    if($null -ne $Context.NotifyIcon){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.SetUiVisible @($Context.NotifyIcon,$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED'}
    if($wasMenuOpen){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.EndMenu @() 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_NATIVE_MENU_END_FAILED'}
    if($null -ne $Context.Timer){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.StopUiTimer @($Context.Timer) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED'
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.Timer) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED'
    }
    foreach($attachment in @($Context.Callbacks)){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DetachUiCallback @($attachment) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED'
    }
    if($null -ne $Context.NotifyIcon){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.NotifyIcon,'ContextMenu',$null) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED'
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.NotifyIcon) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED'
    }
    if($null -ne $Context.Menu){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.Menu) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED'}
    foreach($icon in @($Context.Icons.Values)){
        if($null -ne $icon){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeIconResource @($icon) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED'}
    }
    if($null -ne $Context.ApplicationContext){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.ExitUiContext @($Context.ApplicationContext) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED'
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.ApplicationContext) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED'
    }
    $Context.OnTick=$null;$Context.Callbacks.Clear();$Context.State='Closed'
    $safeCodes=@($codes|Where-Object {$script:TrayCleanupCodeAllowlist -ccontains $_}|Select-Object -Unique)
    $Context.CloseReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=$safeCodes}
    return $Context.CloseReceipt
    }finally{[Threading.Monitor]::Exit($closeGate)}
}

function Test-CcodControlCharacter {
    param([string]$Value)
    foreach($character in $Value.ToCharArray()){if([char]::IsControl($character)){return $true}}
    return $false
}

function Assert-CcodTrayPresentation {
    param($Presentation)
    $names=@('Color','StateKey','SessionReadyVisible','ApplyNowVisible','ApplyNowEnabled','ManualRetryVisible','ManualRetryEnabled','AutomationToggleEnabled','AutomationChecked','CandidateOptInToggleEnabled','CandidateOptInChecked','OpenLogsEnabled','Busy')
    if(-not (Test-CcodExactProperties $Presentation $names)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    if($Presentation.Color -isnot [string] -or @('Gray','Green','Yellow','Red') -cnotcontains $Presentation.Color){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    if($Presentation.StateKey -isnot [string] -or @('Waiting','Inspecting','Transitioning','Active','ActivePaused','RendererHandoff','Suppressed','Recovered','Error') -cnotcontains $Presentation.StateKey){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    foreach($name in $names[2..12]){if($Presentation.$name -isnot [bool]){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}}
}

function ConvertTo-CcodTrayLegacyPresentation {
    param($Presentation)
    try{
        $names=@('Color','ConnectionState','ProtectionState','RepairEnabled','LanguageEnabled','OpenLogsEnabled','AboutEnabled','ExitEnabled','Busy')
        if(-not(Test-CcodExactProperties $Presentation $names)){return $Presentation}
        if($Presentation.Color-isnot[string]-or@('Gray','Green','Yellow','Red')-cnotcontains$Presentation.Color-or@('WaitingForCodex','Checking','Connected','RepairNeeded','Error')-cnotcontains$Presentation.ConnectionState-or@('Running','Reconnecting','Stopping')-cnotcontains$Presentation.ProtectionState){return $Presentation}
        foreach($name in $names[3..8]){if($Presentation.$name-isnot[bool]){return $Presentation}}
        $state=switch($Presentation.ConnectionState){'WaitingForCodex'{'Waiting'}'Checking'{'Inspecting'}'Connected'{'Active'}'RepairNeeded'{'Suppressed'}default{'Error'}}
        return [pscustomobject][ordered]@{
            Color=$Presentation.Color;StateKey=$state;SessionReadyVisible=[bool]($Presentation.ConnectionState-ceq'Connected');ApplyNowVisible=[bool]($Presentation.ConnectionState-ceq'RepairNeeded');ApplyNowEnabled=[bool]$Presentation.RepairEnabled;ManualRetryVisible=[bool]($Presentation.ConnectionState-in@('RepairNeeded','Error'));ManualRetryEnabled=[bool]$Presentation.RepairEnabled
            AutomationToggleEnabled=$false;AutomationChecked=$false;CandidateOptInToggleEnabled=$false;CandidateOptInChecked=$false;OpenLogsEnabled=[bool]$Presentation.OpenLogsEnabled;Busy=[bool]$Presentation.Busy
        }
    }catch{return $Presentation}
}

function Set-CcodTrayPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Context,[Parameter(Mandatory)][AllowNull()]$Presentation,
        [Parameter(Mandatory)][AllowNull()]$Catalog,[Parameter(Mandatory)][AllowNull()]$LanguageMode,
        [Parameter(Mandatory)][AllowNull()]$SystemCultureName
    )
    if(-not (Test-CcodContextObject $Context)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $queueGate=$Context.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
    if($Context.State -cne 'Open'){Throw-CcodTrayError 'CCOD_TRAY_CONTEXT_CLOSED' 'Tray'}
    $Presentation=ConvertTo-CcodTrayLegacyPresentation $Presentation
    Assert-CcodTrayPresentation $Presentation
    $localized=Resolve-CcodTrayLocalizedStrings $Catalog $LanguageMode $SystemCultureName
    $current=Invoke-CcodTrayAdapter $Context.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
    if($current -isnot [int] -or $current -ne $Context.OwnerManagedThreadId){Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
    try{
        $render=New-CcodTrayRenderState $Presentation $localized $LanguageMode $SystemCultureName
        if(-not (Test-CcodTrayRenderState $render)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
        if($Context.MenuOpen){
            if($render.Fingerprint -ceq $Context.LastAppliedFingerprint){$Context.PendingRender=$null;return}
            $Context.PendingRender=$render;return
        }
        if($render.Fingerprint -ceq $Context.LastAppliedFingerprint){return}
        Invoke-CcodTrayRenderWrite $Context $render 'CCOD_TRAY_PRESENTATION_FAILED'
    }catch{Throw-CcodTrayError 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'}
    }finally{[Threading.Monitor]::Exit($queueGate)}
}

function Show-CcodTrayError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Context,[Parameter(Mandatory)][AllowNull()]$Catalog,
        [Parameter(Mandatory)][AllowNull()]$Key
    )
    if(-not (Test-CcodContextObject $Context) -or $Key -isnot [string] -or @('Error.LanguageChange') -cnotcontains $Key -or
       -not (Test-CcodTrayCatalog $Catalog)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $queueGate=$Context.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
        if($Context.State -cne 'Open'){Throw-CcodTrayError 'CCOD_TRAY_CONTEXT_CLOSED' 'Tray'}
        $current=Invoke-CcodTrayAdapter $Context.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
        $apartment=Invoke-CcodTrayAdapter $Context.Adapters.GetApartmentState @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
        if($current -isnot [int] -or $current -ne $Context.OwnerManagedThreadId -or $apartment -isnot [string] -or $apartment -cne 'STA'){Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
        try{$title=Get-CcodUiString -Catalog $Catalog -Key 'Tray.Title';$message=Get-CcodUiString -Catalog $Catalog -Key $Key}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
        Invoke-CcodTrayAdapter $Context.Adapters.ShowErrorDialog @($title,$message) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
    }finally{[Threading.Monitor]::Exit($queueGate)}
}

function Start-CcodProcessWatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Queue,[Parameter(Mandatory)][AllowNull()]$OnFullReconciliationRequired,[AllowNull()]$Adapters)
    if($null -eq $Queue -or $OnFullReconciliationRequired -isnot [scriptblock]){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    $adapter=Get-CcodTrayAdapters $Adapters 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
    $watcher=[pscustomobject][ordered]@{
        SchemaVersion=1;State='Starting';Mode='ReconciliationOnly';Queue=$Queue;OnFullReconciliationRequired=$OnFullReconciliationRequired
        QueueGate=New-Object object;StopGate=New-Object object;FullReconciliationNeeded=$false;OverflowEpisodeSignaled=$false;CallbackFailure=$false
        Registration=$null;Callback=$null;Adapters=$adapter;PendingAttemptSources=[Collections.Generic.List[string]]::new();CapabilityCleanupFailed=$false
        CleanupCodes=[Collections.Generic.List[string]]::new();StopReceipt=$null
    }
    $watcher.PSObject.TypeNames.Insert(0,'Ccod.ProcessWatcher')
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$Queue
    $initialCount=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
    if($initialCount -isnot [int] -or $initialCount -lt 0 -or $initialCount -gt 256){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    $watcherRef=$watcher;$getCanonicalUtcRef=${function:Get-CcodCanonicalUtc};$invokeAdapterRef=${function:Invoke-CcodTrayAdapter};$throwTrayErrorRef=${function:Throw-CcodTrayError}
    $traceClass='Win32_ProcessStartTrace'
    $intrinsicQuery=[string]::Join("`r`n",@(
        'SELECT * FROM __InstanceCreationEvent WITHIN 1',
        "WHERE TargetInstance ISA 'Win32_Process'",
        "AND TargetInstance.Name = 'ChatGPT.exe'"
    ))
    $callback={
        param($ProcessId,$ProcessName)
        [Threading.Monitor]::Enter($watcherRef.QueueGate)
        try{
            if($watcherRef.State -cne 'Running'){return}
            if($ProcessName -isnot [string] -or $ProcessName -cne 'ChatGPT.exe'){return}
            if($ProcessId -is [uint32]){if([uint64]$ProcessId -gt [int]::MaxValue){return};$canonicalPid=[int]$ProcessId}
            elseif($ProcessId -is [int]){$canonicalPid=$ProcessId}else{return}
            if($canonicalPid -le 0){return}
            $event=[pscustomobject][ordered]@{ProcessId=$canonicalPid;EventKind='Started';ObservedAtUtc=(& $getCanonicalUtcRef $watcherRef.Adapters 'CCOD_WATCHER_INPUT_INVALID' 'Watcher')}
            $signal=$false
            $queueArgument=[object[]]::new(1);$queueArgument[0]=$watcherRef.Queue
            $count=& $invokeAdapterRef $watcherRef.Adapters.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
            if($count -isnot [int] -or $count -lt 0){& $throwTrayErrorRef 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            if($count -ge 256){
                $watcherRef.FullReconciliationNeeded=$true
                if(-not $watcherRef.OverflowEpisodeSignaled){$watcherRef.OverflowEpisodeSignaled=$true;$signal=$true}
            }else{
                $enqueueArguments=[object[]]::new(2);$enqueueArguments[0]=$watcherRef.Queue;$enqueueArguments[1]=$event
                $added=& $invokeAdapterRef $watcherRef.Adapters.TryEnqueue $enqueueArguments 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
                if($added -isnot [bool] -or -not $added){
                    $watcherRef.FullReconciliationNeeded=$true
                    if(-not $watcherRef.OverflowEpisodeSignaled){$watcherRef.OverflowEpisodeSignaled=$true;$signal=$true}
                }else{
                    $watcherRef.OverflowEpisodeSignaled=$false
                }
            }
            if($signal){& $invokeAdapterRef $watcherRef.OnFullReconciliationRequired @() 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
        }catch{if($watcherRef.State -ceq 'Running'){$watcherRef.CallbackFailure=$true}}
        finally{[Threading.Monitor]::Exit($watcherRef.QueueGate)}
    }.GetNewClosure()
    $watcher.Callback=$callback
    $generatedSources=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($mode in @('Trace','Intrinsic')){
        $source=$null;$receipt=$null;$registrationAttempted=$false
        try{
            $source=Invoke-CcodTrayAdapter $adapter.NewSourceIdentifier @() 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
            if($source -isnot [string] -or $source -cnotmatch '^ccod-process-[0-9a-f]{32}$'){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            if(-not $generatedSources.Add($source)){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            $register=if($mode -ceq 'Trace'){$adapter.RegisterTrace}else{$adapter.RegisterIntrinsic}
            $registerArguments=if($mode -ceq 'Trace'){@($source,$traceClass,$callback)}else{@($source,$intrinsicQuery,$callback)}
            $registrationAttempted=$true
            $receipt=Invoke-CcodTrayAdapter $register $registerArguments 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
            if(-not (Test-CcodExactProperties $receipt @('SourceIdentifier','JobId','Resource')) -or $receipt.SourceIdentifier -isnot [string] -or
               $receipt.SourceIdentifier -cne $source -or $receipt.JobId -isnot [int] -or $receipt.JobId -le 0 -or $null -eq $receipt.Resource){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            $watcher.Registration=$receipt;$watcher.Mode=$mode;break
        }catch{
            if($registrationAttempted){
                try{Invoke-CcodTrayAdapter $adapter.CleanupWatcherAttempt @($source) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{
                    $watcher.PendingAttemptSources.Add($source);$watcher.CapabilityCleanupFailed=$true;break
                }
            }
        }
    }
    [Threading.Monitor]::Enter($watcher.QueueGate)
    try{$watcher.State='Running'}finally{[Threading.Monitor]::Exit($watcher.QueueGate)}
    return $watcher
}

function Stop-CcodProcessWatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Watcher)
    if(-not (Test-CcodWatcherGateHandle $Watcher)){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    $stopGate=$Watcher.StopGate
    try{[Threading.Monitor]::Enter($stopGate)}catch{Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    try{
    if(-not (Test-CcodWatcherObject $Watcher)){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    if($Watcher.State -ceq 'Stopped'){return $Watcher.StopReceipt}
    if($Watcher.State -ceq 'Stopping'){return $Watcher.StopReceipt}
    $queueGate=$Watcher.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    try{
        $Watcher.State='Stopping'
        $Watcher.StopReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=@()}
    }finally{[Threading.Monitor]::Exit($queueGate)}
    $codes=[Collections.Generic.List[string]]::new();$Watcher.CleanupCodes=$codes;$adapter=$Watcher.Adapters;$receipt=$Watcher.Registration
    try{
        foreach($source in @($Watcher.PendingAttemptSources|Select-Object -First 2)){
            if($source -is [string] -and $source -cmatch '^ccod-process-[0-9a-f]{32}$'){
                Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.CleanupWatcherAttempt @($source) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_ATTEMPT_FAILED' 'Watcher'
            }
        }
        if($null -ne $receipt){
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DetachWatcherCallback @($receipt) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_CALLBACK_DETACH_FAILED' 'Watcher'
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.UnregisterWatcher @($receipt.SourceIdentifier) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_UNREGISTER_FAILED' 'Watcher'
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.RemoveWatcherJob @($receipt.JobId) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_JOB_REMOVE_FAILED' 'Watcher'
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeWatcherResource @($receipt.Resource) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_RESOURCE_DISPOSE_FAILED' 'Watcher'
        }
    }finally{
        $queueArgument=[object[]]::new(1);$queueArgument[0]=$Watcher.Queue
        $drainCount=$null
        try{$drainCount=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}
        if($drainCount -isnot [int] -or $drainCount -lt 0){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}else{
            $drainLimit=[Math]::Min($drainCount,256)
            $earlyEmpty=$false
            for($drained=0;$drained -lt $drainLimit;$drained++){
                $dequeued=$null
                try{$dequeued=Invoke-CcodTrayAdapter $adapter.TryDequeue $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED';break}
                if(-not (Test-CcodExactProperties $dequeued @('Succeeded','Value')) -or $dequeued.Succeeded -isnot [bool]){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED';break}
                if(-not $dequeued.Succeeded){$earlyEmpty=$true;break}
            }
            if($earlyEmpty){
                $remaining=$null
                try{$remaining=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}
                if($remaining -isnot [int] -or $remaining -ne 0){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}
            }
            if($drainCount -gt 256){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_LIMIT'}
        }
        $Watcher.Callback=$null;$Watcher.OnFullReconciliationRequired=$null;$Watcher.State='Stopped'
    }
    $safeCodes=@($codes|Where-Object {$script:WatcherCleanupCodeAllowlist -ccontains $_}|Select-Object -Unique)
    $Watcher.StopReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=$safeCodes}
    return $Watcher.StopReceipt
    }finally{[Threading.Monitor]::Exit($stopGate)}
}

Export-ModuleMember -Function @(
    'New-CcodTrayContext','Set-CcodTrayPresentation','Show-CcodTrayError','Close-CcodTrayContext','Start-CcodProcessWatcher','Stop-CcodProcessWatcher'
)
