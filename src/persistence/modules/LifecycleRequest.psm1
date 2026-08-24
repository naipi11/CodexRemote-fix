Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

$script:CcodLifecycleSubmissionFields=@('schemaVersion','submissionId','kind','origin','runtimeId','runtimeGeneration','createdAtUtc')
$script:CcodLifecycleSubmissionReceiptFields=@('schemaVersion','submissionId','accepted','transactionId','errorCode','completedAtUtc')
$script:CcodLifecycleSubmissionKinds=@('RestartAndRepair','CheckAndRepair','SafeExit')
$script:CcodLifecycleSubmissionOrigins=@('Installer','Tray','ExplicitStart','Guardian')
$script:CcodLifecycleMaximumPending=8

function Throw-CcodLifecycleSubmissionError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodLifecycleSubmissionErrorId {
    param($ErrorRecord)
    if($null-eq$ErrorRecord -or $ErrorRecord.FullyQualifiedErrorId-isnot[string]){return $null}
    return ([string]$ErrorRecord.FullyQualifiedErrorId-split',')[0]
}

function Test-CcodLifecycleSubmissionGuid {
    param($Value)
    $parsed=[guid]::Empty
    return $Value-is[string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D')-ceq$Value
}

function Test-CcodLifecycleSubmissionUtc {
    param($Value)
    $parsed=[DateTime]::MinValue
    return $Value-is[string] -and [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind-eq[DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-ceq$Value
}

function ConvertTo-CcodLifecycleSubmissionUInt64 {
    param($Value,[string]$Name)
    if($Value-is[decimal]){
        if($Value-lt 1 -or [decimal]::Truncate($Value)-ne$Value){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Name must be a positive unsigned integer" $Value}
        try{return [UInt64]$Value}catch{Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Name exceeds UInt64" $Value}
    }
    if($Value-isnot[byte] -and $Value-isnot[uint16] -and $Value-isnot[uint32] -and $Value-isnot[uint64] -and $Value-isnot[int16] -and $Value-isnot[int32] -and $Value-isnot[int64]){
        Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Name must be a positive unsigned integer" $Value
    }
    if($Value-lt 1){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Name must be positive" $Value}
    try{return [UInt64]$Value}catch{Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Name exceeds UInt64" $Value}
}

function Get-CcodLifecycleSubmissionProperties {
    param($Value)
    if($Value-is[Collections.IDictionary]){return @($Value.Keys|ForEach-Object{[string]$_})}
    if($null-eq$Value){return @()}
    return @($Value.PSObject.Properties.Name)
}

function Assert-CcodLifecycleSubmissionExactObject {
    param($Value,[string[]]$Expected,[string]$Kind)
    if($Value-isnot[pscustomobject] -and $Value-isnot[Collections.IDictionary]){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Kind must be an object" $Value}
    $actual=@(Get-CcodLifecycleSubmissionProperties $Value)
    if(($actual-join"`0")-cne($Expected-join"`0")){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Kind has unexpected missing or reordered fields" $Value}
    foreach($property in @($Value.PSObject.Properties)){if($property.MemberType -notin @('NoteProperty','Property')){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' "$Kind contains a non-data property" $Value}}
}

function Assert-CcodLifecycleSubmission {
    param($Submission)
    Assert-CcodLifecycleSubmissionExactObject $Submission $script:CcodLifecycleSubmissionFields 'Lifecycle submission'
    if($Submission.schemaVersion-isnot[int] -or $Submission.schemaVersion-ne 1 -or -not(Test-CcodLifecycleSubmissionGuid $Submission.submissionId) -or
        $Submission.kind-isnot[string] -or $script:CcodLifecycleSubmissionKinds-cnotcontains$Submission.kind -or $Submission.origin-isnot[string] -or $script:CcodLifecycleSubmissionOrigins-cnotcontains$Submission.origin -or
        $Submission.runtimeId-isnot[string] -or $Submission.runtimeId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or -not(Test-CcodLifecycleSubmissionUtc $Submission.createdAtUtc)){
        Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Lifecycle submission fields are invalid' $Submission
    }
    $Submission.runtimeGeneration=ConvertTo-CcodLifecycleSubmissionUInt64 $Submission.runtimeGeneration 'runtimeGeneration'
    return $Submission
}

function Assert-CcodLifecycleSubmissionReceipt {
    param($Receipt,[AllowNull()][string]$ExpectedSubmissionId)
    Assert-CcodLifecycleSubmissionExactObject $Receipt $script:CcodLifecycleSubmissionReceiptFields 'Lifecycle submission receipt'
    if($Receipt.schemaVersion-isnot[int] -or $Receipt.schemaVersion-ne 1 -or -not(Test-CcodLifecycleSubmissionGuid $Receipt.submissionId) -or $Receipt.accepted-isnot[bool] -or
        -not(Test-CcodLifecycleSubmissionUtc $Receipt.completedAtUtc) -or ($null-ne$ExpectedSubmissionId -and $Receipt.submissionId-cne$ExpectedSubmissionId)){
        Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_RECEIPT_INVALID' 'Lifecycle submission receipt is invalid' $Receipt
    }
    if($Receipt.accepted){
        if(-not(Test-CcodLifecycleSubmissionGuid $Receipt.transactionId) -or $null-ne$Receipt.errorCode){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_RECEIPT_INVALID' 'Accepted lifecycle receipt is invalid' $Receipt}
    }elseif($null-ne$Receipt.transactionId -or $Receipt.errorCode-isnot[string] -or $Receipt.errorCode-cnotmatch'^[A-Z][A-Z0-9_]{0,127}$'){
        Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_RECEIPT_INVALID' 'Rejected lifecycle receipt is invalid' $Receipt
    }
    return $Receipt
}

function Get-CcodLifecycleSubmissionTimestamp {
    param([hashtable]$Adapters)
    $now=&$Adapters.GetUtcNow
    if($now-isnot[DateTime]){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_CLOCK_INVALID' 'Lifecycle clock must return DateTime' $now}
    return $now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function Get-CcodLifecycleSubmissionIdentity {
    $windows=$null;$process=$null
    try{
        $windows=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess()
        if($null-eq$windows.User){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Current user SID is unavailable' $null}
        return [pscustomobject][ordered]@{UserSid=$windows.User.Value;SessionId=[int]$process.SessionId}
    }finally{if($null-ne$process){$process.Dispose()};if($null-ne$windows){$windows.Dispose()}}
}

function Get-CcodLifecycleSubmissionDirectorySecurity {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{
        if($null-eq$identity.User){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Current user SID is unavailable' $null}
        $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false)
        foreach($sidValue in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidValue),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]::ContainerInherit-bor[Security.AccessControl.InheritanceFlags]::ObjectInherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
            [void]$security.AddAccessRule($rule)
        }
        return $security
    }finally{$identity.Dispose()}
}

function Assert-CcodLifecycleSubmissionAcl {
    param([string]$Path,[switch]$Directory)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{
        $security=if($Directory){[IO.Directory]::GetAccessControl($Path)}else{[IO.File]::GetAccessControl($Path)}
        $owner=$security.GetOwner([Security.Principal.SecurityIdentifier]);$rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));$expected=@($identity.User.Value,'S-1-5-18','S-1-5-32-544')
        if($null-eq$identity.User -or $null-eq$owner -or $owner.Value-cne$identity.User.Value -or -not$security.AreAccessRulesProtected -or $rules.Count-ne 3){
            Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Lifecycle inbox ACL is invalid' $Path
        }
        foreach($rule in $rules){if($rule.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow -or $rule.IsInherited -or $rule.FileSystemRights-ne[Security.AccessControl.FileSystemRights]::FullControl -or $expected-cnotcontains$rule.IdentityReference.Value){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Lifecycle inbox ACL is invalid' $Path}}
    }catch{if((Get-CcodLifecycleSubmissionErrorId $_)-ceq'CCOD_LIFECYCLE_ACL_INVALID'){throw};Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Lifecycle inbox ACL could not be proven' $Path}
    finally{$identity.Dispose()}
}

function Get-CcodLifecycleSubmissionFileSecurity {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{
        if($null-eq$identity.User){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Current user SID is unavailable' $null}
        $security=[Security.AccessControl.FileSecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false)
        foreach($sidValue in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')){
            [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidValue),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
        }
        return $security
    }finally{$identity.Dispose()}
}

function Set-CcodLifecycleSubmissionFileAcl {
    param([string]$Path)
    try{
        [IO.File]::SetAccessControl($Path,(Get-CcodLifecycleSubmissionFileSecurity))
        Assert-CcodLifecycleSubmissionAcl $Path
    }catch{if((Get-CcodLifecycleSubmissionErrorId $_)-ceq'CCOD_LIFECYCLE_ACL_INVALID'){throw};Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Lifecycle submission file ACL could not be established' $Path}
}

function Get-CcodLifecycleInboxPath {
    param([string]$StateRoot,[switch]$Create)
    try{
        $state=[IO.Path]::GetFullPath($StateRoot)
        $inbox=Resolve-CcodContainedPath -Root $state -RelativePath 'lifecycle\inbox' -AllowMissingLeaf
        if($Create){
            if(-not[IO.Directory]::Exists($inbox)){[void][IO.Directory]::CreateDirectory($inbox,(Get-CcodLifecycleSubmissionDirectorySecurity))}
            else{[IO.Directory]::SetAccessControl($inbox,(Get-CcodLifecycleSubmissionDirectorySecurity))}
        }
        $inbox=Resolve-CcodContainedPath -Root $state -RelativePath 'lifecycle\inbox'
        $item=Get-Item -LiteralPath $inbox -Force -ErrorAction Stop
        if(-not$item.PSIsContainer -or ($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'inbox'}
        Assert-CcodLifecycleSubmissionAcl $inbox -Directory
        return $inbox
    }catch{if((Get-CcodLifecycleSubmissionErrorId $_)-ceq'CCOD_LIFECYCLE_ACL_INVALID'){throw};Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_PATH_INVALID' 'Lifecycle inbox path is unsafe' $StateRoot}
}

function Get-CcodLifecycleSubmissionLeafPath {
    param([string]$Inbox,[string]$SubmissionId,[ValidateSet('request','receipt')][string]$Kind)
    if(-not(Test-CcodLifecycleSubmissionGuid $SubmissionId)){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Submission ID is invalid' $SubmissionId}
    $leaf=$SubmissionId+'.'+$Kind+'.json'
    $path=[IO.Path]::GetFullPath((Join-Path $Inbox $leaf))
    if((Split-Path $path-Parent)-cne$Inbox -or [IO.Path]::GetFileName($path)-cne$leaf){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_PATH_INVALID' 'Lifecycle leaf is not a canonical direct child' $path}
    return $path
}

function Get-CcodLifecyclePendingFiles {
    param([string]$Inbox)
    $files=@(Get-ChildItem -LiteralPath $Inbox -Filter '*.request.json' -Force|Sort-Object Name)
    foreach($file in $files){
        if($file-isnot[IO.FileInfo] -or $file.PSIsContainer -or ($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0 -or $file.DirectoryName-cne$Inbox -or $file.Name-cnotmatch'^(?<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.request\.json$' -or -not(Test-CcodLifecycleSubmissionGuid $Matches.id)){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_PATH_INVALID' 'Lifecycle request leaf is unsafe' $file.FullName}
        Assert-CcodLifecycleSubmissionAcl $file.FullName
    }
    if($files.Count-gt$script:CcodLifecycleMaximumPending){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_INBOX_FULL' 'Lifecycle inbox exceeds its bounded capacity' $Inbox}
    return $files
}

function Assert-CcodLifecycleSubmissionLeaf {
    param([string]$Path,[string]$Inbox,[switch]$AllowMissing)
    try{$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop}
    catch [Management.Automation.ItemNotFoundException]{if($AllowMissing){return};throw}
    if($item-isnot[IO.FileInfo] -or $item.PSIsContainer -or ($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0 -or $item.DirectoryName-cne$Inbox){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_PATH_INVALID' 'Lifecycle inbox leaf is unsafe' $Path}
    Assert-CcodLifecycleSubmissionAcl $Path
}

function Get-CcodLifecycleWakeName {
    param([string]$UserSid,[int]$SessionId)
    if($UserSid-cnotmatch'^S-\d-\d+(?:-\d+)+$' -or $SessionId-lt0){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Lifecycle wake identity is invalid' $null}
    return "Local\CodexControlOtherDevices.LifecycleWake.$UserSid.$SessionId"
}

function Get-CcodLifecycleInboxHash {
    param([string]$Inbox)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Inbox.ToLowerInvariant()))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-CcodLifecycleWakeAcl {
    param([Threading.EventWaitHandle]$Handle,[string]$UserSid)
    try{
        $security=$Handle.GetAccessControl();$owner=$security.GetOwner([Security.Principal.SecurityIdentifier]);$rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));$expected=@($UserSid,'S-1-5-18','S-1-5-32-544')
        if($owner.Value-cne$UserSid -or -not$security.AreAccessRulesProtected -or $rules.Count-ne3){throw 'acl'}
        foreach($rule in $rules){if($rule.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow -or $rule.EventWaitHandleRights-ne[Security.AccessControl.EventWaitHandleRights]::FullControl -or $expected-cnotcontains$rule.IdentityReference.Value){throw 'acl'}}
    }catch{Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_ACL_INVALID' 'Lifecycle wake event ACL is invalid' $null}
}

function Open-CcodLifecycleSubmissionWakeEvent {
    param([string]$UserSid,[int]$SessionId)
    $rights=[Security.AccessControl.EventWaitHandleRights]::ReadPermissions-bor[Security.AccessControl.EventWaitHandleRights]::Synchronize-bor[Security.AccessControl.EventWaitHandleRights]::Modify
    $handle=[Threading.EventWaitHandle]::OpenExisting((Get-CcodLifecycleWakeName $UserSid $SessionId),$rights)
    Assert-CcodLifecycleWakeAcl $handle $UserSid
    return $handle
}

function Get-CcodLifecycleRequestAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        NewGuid={[guid]::NewGuid()};GetUtcNow={[DateTime]::UtcNow};GetIdentity={Get-CcodLifecycleSubmissionIdentity}
        OpenWakeEvent={param($UserSid,$SessionId)Open-CcodLifecycleSubmissionWakeEvent $UserSid $SessionId}
        SignalWakeEvent={param($Handle)[void]$Handle.Set()};DisposeWakeEvent={param($Handle)$Handle.Dispose()}
        StartClock={[Diagnostics.Stopwatch]::StartNew()};GetElapsedMilliseconds={param($Clock)[long]$Clock.ElapsedMilliseconds};Sleep={param($Milliseconds)Start-Sleep -Milliseconds $Milliseconds}
    }
    if($null-ne$Adapters){
        if($Adapters-isnot[hashtable]){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Lifecycle request adapters must be a hashtable' $Adapters}
        foreach($key in $Adapters.Keys){if(-not$resolved.ContainsKey($key) -or $Adapters[$key]-isnot[scriptblock]){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Lifecycle request adapter is invalid' $key};$resolved[$key]=$Adapters[$key]}
    }
    return $resolved
}

function New-CcodLifecycleLocalReceipt {
    param([string]$SubmissionId,[bool]$Accepted,[AllowNull()]$TransactionId,[AllowNull()]$ErrorCode,[hashtable]$Adapters)
    $receipt=[pscustomobject][ordered]@{schemaVersion=1;submissionId=$SubmissionId;accepted=$Accepted;transactionId=$TransactionId;errorCode=$ErrorCode;completedAtUtc=(Get-CcodLifecycleSubmissionTimestamp $Adapters)}
    Assert-CcodLifecycleSubmissionReceipt $receipt $SubmissionId|Out-Null
    return $receipt
}

function Read-CcodLifecycleSubmissionReceiptFile {
    param([string]$Path,[string]$SubmissionId,[string]$CreatedAtUtc)
    if(-not[IO.File]::Exists($Path)){return $null}
    try{
        $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if($item-isnot[IO.FileInfo] -or ($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return $null}
        Assert-CcodLifecycleSubmissionAcl $Path
        $receipt=Read-CcodStrictJson -Path $Path -ExpectedSchema 1 -Kind 'lifecycle submission receipt'
        if($receipt.submissionId-isnot[string] -or $receipt.submissionId-cne$SubmissionId){return $null}
        Assert-CcodLifecycleSubmissionReceipt $receipt $SubmissionId|Out-Null
        $created=[DateTime]::ParseExact($CreatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $completed=[DateTime]::ParseExact($receipt.completedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        if($completed-lt$created){return $null}
        return $receipt
    }catch{return $null}
}

function Submit-CcodLifecycleRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][ValidateSet('RestartAndRepair','CheckAndRepair','SafeExit')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('Installer','Tray','ExplicitStart','Guardian')][string]$Origin,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)][ValidateRange(1,600000)][int]$TimeoutMilliseconds,
        [hashtable]$Adapters
    )
    $adapter=Get-CcodLifecycleRequestAdapters $Adapters
    $guid=&$adapter.NewGuid
    if($guid-isnot[guid]){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Lifecycle submission ID source is invalid' $guid}
    $submissionId=$guid.ToString('D');$createdAt=Get-CcodLifecycleSubmissionTimestamp $adapter
    $submission=[pscustomobject][ordered]@{schemaVersion=1;submissionId=$submissionId;kind=$Kind;origin=$Origin;runtimeId=$RuntimeId;runtimeGeneration=$RuntimeGeneration;createdAtUtc=$createdAt}
    Assert-CcodLifecycleSubmission $submission|Out-Null
    $inbox=$null
    try{$install=[IO.Path]::GetFullPath($InstallRoot);if(-not[IO.Path]::IsPathRooted($InstallRoot) -or $install-cne$InstallRoot){throw 'root'};$state=Resolve-CcodContainedPath -Root $install -RelativePath 'state';$inbox=Get-CcodLifecycleInboxPath $state -Create}
    catch{return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_PATH_INVALID' $adapter}
    $requestPath=Get-CcodLifecycleSubmissionLeafPath $inbox $submissionId request;$receiptPath=Get-CcodLifecycleSubmissionLeafPath $inbox $submissionId receipt
    $mutex=$null;$entered=$false
    try{
        $hash=Get-CcodLifecycleInboxHash $inbox
        $security=[Security.AccessControl.MutexSecurity]::new();$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false);foreach($sidValue in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')){[void]$security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidValue),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))}}finally{$identity.Dispose()}
        $created=$false;$mutex=[Threading.Mutex]::new($false,('Local\CcodLifecycleInbox-'+$hash),[ref]$created,$security)
        try{$entered=$mutex.WaitOne([Math]::Min(5000,$TimeoutMilliseconds))}catch [Threading.AbandonedMutexException]{$entered=$true}
        if(-not$entered){return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_INBOX_BUSY' $adapter}
        if([IO.File]::Exists($requestPath)){return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_SUBMISSION_DUPLICATE' $adapter}
        $pending=@(Get-CcodLifecyclePendingFiles $inbox)
        if($pending.Count-ge$script:CcodLifecycleMaximumPending){return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_INBOX_FULL' $adapter}
        Write-CcodAtomicJsonIfAbsent -Path $requestPath -Value $submission
        Set-CcodLifecycleSubmissionFileAcl $requestPath
    }catch{
        $id=Get-CcodLifecycleSubmissionErrorId $_
        $code=if($id-ceq'CCOD_ATOMIC_TARGET_EXISTS'){'CCOD_LIFECYCLE_SUBMISSION_DUPLICATE'}elseif($id-ceq'CCOD_LIFECYCLE_INBOX_FULL'){'CCOD_LIFECYCLE_INBOX_FULL'}elseif($id -in @('CCOD_LIFECYCLE_PATH_INVALID','CCOD_LIFECYCLE_ACL_INVALID')){'CCOD_LIFECYCLE_PATH_INVALID'}else{'CCOD_LIFECYCLE_SUBMISSION_FAILED'}
        return New-CcodLifecycleLocalReceipt $submissionId $false $null $code $adapter
    }finally{if($entered){$mutex.ReleaseMutex()};if($null-ne$mutex){$mutex.Dispose()}}
    $wake=$null
    try{$identity=&$adapter.GetIdentity;$wake=&$adapter.OpenWakeEvent $identity.UserSid ([int]$identity.SessionId)}catch{return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_SUPERVISOR_UNAVAILABLE' $adapter}
    try{[void](&$adapter.SignalWakeEvent $wake)}catch{return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_WAKE_FAILED' $adapter}
    finally{if($null-ne$wake){try{[void](&$adapter.DisposeWakeEvent $wake)}catch{}}}
    $clock=&$adapter.StartClock
    do{
        $receipt=Read-CcodLifecycleSubmissionReceiptFile $receiptPath $submissionId $createdAt
        if($null-ne$receipt){return $receipt}
        $elapsed=&$adapter.GetElapsedMilliseconds $clock
        if(($elapsed-isnot[int] -and $elapsed-isnot[long]) -or $elapsed-lt0){return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_CLOCK_INVALID' $adapter}
        if([long]$elapsed-ge$TimeoutMilliseconds){break}
        &$adapter.Sleep ([Math]::Min(20,[Math]::Max(1,$TimeoutMilliseconds-[int]$elapsed)))
    }while($true)
    return New-CcodLifecycleLocalReceipt $submissionId $false $null 'CCOD_LIFECYCLE_SUBMISSION_TIMEOUT' $adapter
}

function Receive-CcodLifecycleSubmissions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[ValidateRange(1,8)][int]$MaximumCount=1)
    $inbox=Get-CcodLifecycleInboxPath ([IO.Path]::GetFullPath($StateRoot)) -Create
    $count=0
    foreach($file in @(Get-CcodLifecyclePendingFiles $inbox)){
        if($count-ge$MaximumCount){break}
        $submission=Read-CcodStrictJson -Path $file.FullName -ExpectedSchema 1 -Kind 'lifecycle submission'
        Assert-CcodLifecycleSubmission $submission|Out-Null
        if($file.Name-cne($submission.submissionId+'.request.json')){Throw-CcodLifecycleSubmissionError 'CCOD_LIFECYCLE_SUBMISSION_INVALID' 'Lifecycle request filename is uncorrelated' $file.FullName}
        $receiptPath=Get-CcodLifecycleSubmissionLeafPath $inbox $submission.submissionId receipt
        if($null-ne(Read-CcodLifecycleSubmissionReceiptFile $receiptPath $submission.submissionId $submission.createdAtUtc)){[IO.File]::Delete($file.FullName);continue}
        $count++;Write-Output -NoEnumerate $submission
    }
}

function Write-CcodLifecycleSubmissionReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$SubmissionId,[Parameter(Mandatory)][bool]$Accepted,
        [AllowNull()]$TransactionId,[AllowNull()]$ErrorCode,[hashtable]$Adapters
    )
    $adapter=Get-CcodLifecycleRequestAdapters $Adapters
    $inbox=Get-CcodLifecycleInboxPath ([IO.Path]::GetFullPath($StateRoot)) -Create
    $receipt=New-CcodLifecycleLocalReceipt $SubmissionId $Accepted $TransactionId $ErrorCode $adapter
    $receiptPath=Get-CcodLifecycleSubmissionLeafPath $inbox $SubmissionId receipt;$requestPath=Get-CcodLifecycleSubmissionLeafPath $inbox $SubmissionId request
    Assert-CcodLifecycleSubmissionLeaf $receiptPath $inbox -AllowMissing
    Write-CcodAtomicJson -Path $receiptPath -Value $receipt;Set-CcodLifecycleSubmissionFileAcl $receiptPath
    if([IO.File]::Exists($requestPath)){
        Assert-CcodLifecycleSubmissionLeaf $requestPath $inbox
        [IO.File]::Delete($requestPath)
    }
    return $receipt
}

Export-ModuleMember -Function Submit-CcodLifecycleRequest,Receive-CcodLifecycleSubmissions,Write-CcodLifecycleSubmissionReceipt
