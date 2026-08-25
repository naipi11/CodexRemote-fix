Set-StrictMode -Version Latest

$script:CcodKernelMutexKinds=@('AccountSupervisor','AccountTransition','Supervisor','Transition')
$script:CcodKernelLocalKinds=@('Supervisor','Transition','Shutdown','Ready')
$script:CcodKernelAccountKinds=@('AccountSupervisor','AccountTransition')
$script:CcodKernelAllKinds=@('AccountSupervisor','AccountTransition','Supervisor','Transition','Shutdown','Ready')
$script:CcodKernelMaximumNameLength=260
$script:CcodKernelStableErrorIds=@('CCOD_KERNEL_INPUT_INVALID','CCOD_KERNEL_ACL_MISMATCH','CCOD_KERNEL_OBJECT_TYPE_MISMATCH','CCOD_KERNEL_ACCESS_DENIED','CCOD_KERNEL_OPEN_FAILED','CCOD_KERNEL_LEASE_INVALID','CCOD_KERNEL_RELEASE_FAILED')

function Throw-CcodKernelError {
    param($Id,$Category)
    $exception=[InvalidOperationException]::new('The protected kernel-object operation failed safely.')
    throw [Management.Automation.ErrorRecord]::new($exception,$Id,$Category,$null)
}

function Throw-CcodNormalizedKernelError {
    param($Failure,[string]$FallbackId)
    $id=$FallbackId
    if($null -ne $Failure -and $Failure.FullyQualifiedErrorId -is [string]){
        $candidate=($Failure.FullyQualifiedErrorId -split ',')[0]
        if($script:CcodKernelStableErrorIds -ccontains $candidate){$id=$candidate}
    }
    $category=switch($id){
        'CCOD_KERNEL_INPUT_INVALID' {[Management.Automation.ErrorCategory]::InvalidArgument;break}
        'CCOD_KERNEL_ACL_MISMATCH' {[Management.Automation.ErrorCategory]::SecurityError;break}
        'CCOD_KERNEL_OBJECT_TYPE_MISMATCH' {[Management.Automation.ErrorCategory]::InvalidType;break}
        'CCOD_KERNEL_ACCESS_DENIED' {[Management.Automation.ErrorCategory]::SecurityError;break}
        'CCOD_KERNEL_LEASE_INVALID' {[Management.Automation.ErrorCategory]::InvalidData;break}
        'CCOD_KERNEL_RELEASE_FAILED' {[Management.Automation.ErrorCategory]::InvalidOperation;break}
        default {[Management.Automation.ErrorCategory]::OpenError}
    }
    Throw-CcodKernelError $id $category
}

function Get-CcodCurrentUserSidValue {
    $identity=$null
    try{
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        if($null -eq $identity -or $null -eq $identity.User){Throw-CcodKernelError 'CCOD_KERNEL_ACCESS_DENIED' ([Management.Automation.ErrorCategory]::SecurityError)}
        return $identity.User.Value
    }catch{
        Throw-CcodNormalizedKernelError $_ 'CCOD_KERNEL_ACCESS_DENIED'
    }finally{if($null -ne $identity){$identity.Dispose()}}
}

function Get-CcodCanonicalSid {
    param($Value)
    if($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOfAny([char[]]'\/') -ge 0){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    try{$sid=[Security.Principal.SecurityIdentifier]::new($Value)}catch{Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    if($sid.Value -cne $Value){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    return $sid
}

function Assert-CcodCurrentUserSid {
    param($UserSid)
    $sid=Get-CcodCanonicalSid $UserSid
    if((Get-CcodCurrentUserSidValue) -cne $sid.Value){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    return $sid
}

function Assert-CcodExactSessionId {
    param($Value)
    if($Value -isnot [int] -or $Value -lt 0){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    return [int]$Value
}

function Get-CcodKernelObjectName {
    [CmdletBinding()]
    param($Kind,$UserSid,$SessionId,$ReadyToken)

    if($Kind -isnot [string] -or $script:CcodKernelAllKinds -cnotcontains $Kind){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    $sid=Get-CcodCanonicalSid $UserSid
    $hasSession=$PSBoundParameters.ContainsKey('SessionId')
    $hasToken=$PSBoundParameters.ContainsKey('ReadyToken')
    if($script:CcodKernelAccountKinds -ccontains $Kind){
        if($hasSession -or $hasToken){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
        $name="Global\CodexControlOtherDevices.$Kind.$($sid.Value)"
    }else{
        if(-not $hasSession){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
        $exactSession=Assert-CcodExactSessionId $SessionId
        if($Kind -ceq 'Ready'){
            if(-not $hasToken -or $ReadyToken -isnot [string] -or $ReadyToken -cnotmatch '^[0-9a-f]{64}$'){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
            $name="Local\CodexControlOtherDevices.Ready.$($sid.Value).$exactSession.$ReadyToken"
        }else{
            if($hasToken){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
            $name="Local\CodexControlOtherDevices.$Kind.$($sid.Value).$exactSession"
        }
    }
    if($name.Length -gt $script:CcodKernelMaximumNameLength){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::LimitsExceeded)}
    return $name
}

function New-CcodMutexSecurity {
    [CmdletBinding()]
    param($UserSid)
    $sid=Assert-CcodCurrentUserSid $UserSid
    try{
        $security=[Security.AccessControl.MutexSecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true,$false)
        foreach($identityValue in @($sid.Value,'S-1-5-18','S-1-5-32-544')){
            $identity=[Security.Principal.SecurityIdentifier]::new($identityValue)
            $rule=[Security.AccessControl.MutexAccessRule]::new($identity,[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
            [void]$security.AddAccessRule($rule)
        }
        return $security
    }catch{
        Throw-CcodNormalizedKernelError $_ 'CCOD_KERNEL_OPEN_FAILED'
    }
}

function New-CcodEventSecurity {
    [CmdletBinding()]
    param($UserSid)
    $sid=Assert-CcodCurrentUserSid $UserSid
    try{
        $security=[Security.AccessControl.EventWaitHandleSecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true,$false)
        foreach($identityValue in @($sid.Value,'S-1-5-18','S-1-5-32-544')){
            $identity=[Security.Principal.SecurityIdentifier]::new($identityValue)
            $rule=[Security.AccessControl.EventWaitHandleAccessRule]::new($identity,[Security.AccessControl.EventWaitHandleRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
            [void]$security.AddAccessRule($rule)
        }
        return $security
    }catch{
        Throw-CcodNormalizedKernelError $_ 'CCOD_KERNEL_OPEN_FAILED'
    }
}

function Assert-CcodKernelSecurity {
    param($Security,$DescriptorBinary,$UserSid,$ExpectedType,$FullControlMask)
    try{
        if($null -eq $Security -or $Security.GetType() -ne $ExpectedType -or -not $Security.AreAccessRulesProtected){Throw-CcodKernelError 'CCOD_KERNEL_ACL_MISMATCH' ([Management.Automation.ErrorCategory]::SecurityError)}
        if($DescriptorBinary -isnot [byte[]] -or $DescriptorBinary.Length -eq 0){Throw-CcodKernelError 'CCOD_KERNEL_ACL_MISMATCH' ([Management.Automation.ErrorCategory]::SecurityError)}
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($DescriptorBinary,0)
        if(($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -eq 0 -or $null -eq $raw.Owner -or $raw.Owner.Value -cne $UserSid -or $null -eq $raw.DiscretionaryAcl -or $raw.DiscretionaryAcl.Count -ne 3){Throw-CcodKernelError 'CCOD_KERNEL_ACL_MISMATCH' ([Management.Automation.ErrorCategory]::SecurityError)}
        $expected=@($UserSid,'S-1-5-18','S-1-5-32-544')
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($ace in $raw.DiscretionaryAcl){
            if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed -or $ace.AceFlags -ne [Security.AccessControl.AceFlags]::None -or $ace.AccessMask -ne $FullControlMask -or $null -eq $ace.SecurityIdentifier -or $expected -cnotcontains $ace.SecurityIdentifier.Value -or -not $seen.Add($ace.SecurityIdentifier.Value)){
                Throw-CcodKernelError 'CCOD_KERNEL_ACL_MISMATCH' ([Management.Automation.ErrorCategory]::SecurityError)
            }
        }
        if($seen.Count -ne 3){Throw-CcodKernelError 'CCOD_KERNEL_ACL_MISMATCH' ([Management.Automation.ErrorCategory]::SecurityError)}
    }catch{
        $fallback=if($_.Exception -is [UnauthorizedAccessException] -or $_.Exception -is [Security.SecurityException]){'CCOD_KERNEL_ACCESS_DENIED'}else{'CCOD_KERNEL_ACL_MISMATCH'}
        Throw-CcodNormalizedKernelError $_ $fallback
    }
}

function Test-CcodOtherEventType {
    param($Name)
    $handle=$null
    try{
        $rights=[Security.AccessControl.EventWaitHandleRights]::ReadPermissions -bor [Security.AccessControl.EventWaitHandleRights]::Synchronize
        $handle=[Threading.EventWaitHandle]::OpenExisting($Name,$rights)
        return $true
    }catch [Threading.WaitHandleCannotBeOpenedException]{return $false}
    catch [UnauthorizedAccessException]{return $true}
    finally{if($null -ne $handle){$handle.Dispose()}}
}

function Test-CcodOtherMutexType {
    param($Name)
    $handle=$null
    try{
        $rights=[Security.AccessControl.MutexRights]::ReadPermissions -bor [Security.AccessControl.MutexRights]::Synchronize
        $handle=[Threading.Mutex]::OpenExisting($Name,$rights)
        return $true
    }catch [Threading.WaitHandleCannotBeOpenedException]{return $false}
    catch [UnauthorizedAccessException]{return $true}
    finally{if($null -ne $handle){$handle.Dispose()}}
}

function Get-CcodKernelAdapters {
    param($Adapters)
    $resolved=@{
        GetName={param($Kind,$UserSid,$SessionId,$ReadyToken,$DefaultName)$DefaultName}
        CreateMutex={param($Name,$Security)$created=$false;$handle=[Threading.Mutex]::new($false,$Name,[ref]$created,$Security);[pscustomobject]@{Handle=$handle;CreatedNew=$created}}
        GetMutexSecurity={param($Handle)$Handle.GetAccessControl()}
        GetMutexSecurityDescriptor={param($Handle,$Security)$Security.GetSecurityDescriptorBinaryForm()}
        WaitMutex={param($Handle,$TimeoutMilliseconds)$Handle.WaitOne($TimeoutMilliseconds)}
        DisposeHandle={param($Handle)$Handle.Dispose()}
        GetManagedThreadId={ [Threading.Thread]::CurrentThread.ManagedThreadId }
        ReleaseMutex={param($Handle)$Handle.ReleaseMutex()}
        CreateEvent={param($Name,$Security)$created=$false;$handle=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$Name,[ref]$created,$Security);[pscustomobject]@{Handle=$handle;CreatedNew=$created}}
        OpenEvent={param($Name)$rights=[Security.AccessControl.EventWaitHandleRights]::ReadPermissions -bor [Security.AccessControl.EventWaitHandleRights]::Synchronize -bor [Security.AccessControl.EventWaitHandleRights]::Modify;[Threading.EventWaitHandle]::OpenExisting($Name,$rights)}
        GetEventSecurity={param($Handle)$Handle.GetAccessControl()}
        GetEventSecurityDescriptor={param($Handle,$Security)$Security.GetSecurityDescriptorBinaryForm()}
        TestOtherEventType={param($Name)Test-CcodOtherEventType $Name}
        TestOtherMutexType={param($Name)Test-CcodOtherMutexType $Name}
    }
    if($null -ne $Adapters){
        if($Adapters -isnot [hashtable]){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
        foreach($key in $Adapters.Keys){
            if(-not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
            $resolved[$key]=$Adapters[$key]
        }
    }
    return $resolved
}

function Resolve-CcodKernelName {
    param($Kind,$UserSid,$SessionId,$ReadyToken,$HasSession,$HasToken,$Adapter)
    if($HasSession){
        if($HasToken){$default=Get-CcodKernelObjectName -Kind $Kind -UserSid $UserSid -SessionId $SessionId -ReadyToken $ReadyToken}
        else{$default=Get-CcodKernelObjectName -Kind $Kind -UserSid $UserSid -SessionId $SessionId}
    }else{$default=Get-CcodKernelObjectName -Kind $Kind -UserSid $UserSid}
    try{$name=& $Adapter.GetName $Kind $UserSid $(if($HasSession){$SessionId}else{$null}) $(if($HasToken){$ReadyToken}else{$null}) $default}
    catch{Throw-CcodNormalizedKernelError $_ 'CCOD_KERNEL_OPEN_FAILED'}
    if($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt $script:CcodKernelMaximumNameLength){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    $expectedPrefix=if($script:CcodKernelAccountKinds -ccontains $Kind){'Global\'}else{'Local\'}
    if(-not $name.StartsWith($expectedPrefix,[StringComparison]::Ordinal)){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    return $name
}

function Enter-CcodMutex {
    [CmdletBinding()]
    param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds,$Adapters)
    if($Kind -isnot [string] -or $script:CcodKernelMutexKinds -cnotcontains $Kind -or $TimeoutMilliseconds -isnot [int] -or $TimeoutMilliseconds -lt 0 -or $TimeoutMilliseconds -gt 120000){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    $hasSession=$PSBoundParameters.ContainsKey('SessionId')
    $adapter=Get-CcodKernelAdapters $Adapters
    $name=Resolve-CcodKernelName $Kind $UserSid $SessionId $null $hasSession $false $adapter
    $security=New-CcodMutexSecurity -UserSid $UserSid
    $handle=$null;$ownsMutex=$false
    try{
        try{$opened=& $adapter.CreateMutex $name $security}catch [UnauthorizedAccessException]{Throw-CcodKernelError 'CCOD_KERNEL_ACCESS_DENIED' ([Management.Automation.ErrorCategory]::SecurityError)}catch [Threading.WaitHandleCannotBeOpenedException]{if(& $adapter.TestOtherEventType $name){Throw-CcodKernelError 'CCOD_KERNEL_OBJECT_TYPE_MISMATCH' ([Management.Automation.ErrorCategory]::InvalidType)};Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::OpenError)}
        if($null -eq $opened -or $opened.Handle -isnot [Threading.Mutex] -or $opened.CreatedNew -isnot [bool]){Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::OpenError)}
        $handle=$opened.Handle
        $actualSecurity=& $adapter.GetMutexSecurity $handle
        $descriptor=[byte[]]@(& $adapter.GetMutexSecurityDescriptor $handle $actualSecurity)
        Assert-CcodKernelSecurity $actualSecurity $descriptor $UserSid ([Security.AccessControl.MutexSecurity]) ([int][Security.AccessControl.MutexRights]::FullControl)
        $abandoned=$false
        try{$acquired=& $adapter.WaitMutex $handle $TimeoutMilliseconds}catch [Threading.AbandonedMutexException]{$acquired=$true;$abandoned=$true}
        if($acquired -isnot [bool]){Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::InvalidResult)}
        if(-not $acquired){
            & $adapter.DisposeHandle $handle;$handle=$null
            return [pscustomobject][ordered]@{SchemaVersion=1;Name=$name;Kind=$Kind;Outcome='TimedOut';CreatedNew=[bool]$opened.CreatedNew;Abandoned=$false;Handle=$null;OwnerManagedThreadId=$null;Released=$true}
        }
        $ownsMutex=$true
        $threadId=& $adapter.GetManagedThreadId
        if($threadId -isnot [int] -or $threadId -le 0){Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::InvalidResult)}
        $lease=[pscustomobject][ordered]@{SchemaVersion=1;Name=$name;Kind=$Kind;Outcome='Acquired';CreatedNew=[bool]$opened.CreatedNew;Abandoned=[bool]$abandoned;Handle=$handle;OwnerManagedThreadId=$threadId;Released=$false}
        $handle=$null;$ownsMutex=$false
        return $lease
    }catch{
        if($null -ne $handle){if($ownsMutex){try{& $adapter.ReleaseMutex $handle}catch{}};try{& $adapter.DisposeHandle $handle}catch{}}
        $fallback=if($_.Exception -is [UnauthorizedAccessException] -or $_.Exception -is [Security.SecurityException]){'CCOD_KERNEL_ACCESS_DENIED'}else{'CCOD_KERNEL_OPEN_FAILED'}
        Throw-CcodNormalizedKernelError $_ $fallback
    }
}

function Exit-CcodMutex {
    [CmdletBinding()]
    param($Lease)
    $expected=@('SchemaVersion','Name','Kind','Outcome','CreatedNew','Abandoned','Handle','OwnerManagedThreadId','Released')
    if($null -eq $Lease -or ($Lease -isnot [pscustomobject] -and $Lease -isnot [Collections.IDictionary])){Throw-CcodKernelError 'CCOD_KERNEL_LEASE_INVALID' ([Management.Automation.ErrorCategory]::InvalidData)}
    $actual=@($Lease.PSObject.Properties.Name)
    if($actual.Count -ne $expected.Count -or ($actual -join ',') -cne ($expected -join ',') -or $Lease.SchemaVersion -isnot [int] -or $Lease.SchemaVersion -ne 1 -or $Lease.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Lease.Name) -or $script:CcodKernelMutexKinds -cnotcontains $Lease.Kind -or $Lease.CreatedNew -isnot [bool] -or $Lease.Abandoned -isnot [bool] -or $Lease.Released -isnot [bool]){Throw-CcodKernelError 'CCOD_KERNEL_LEASE_INVALID' ([Management.Automation.ErrorCategory]::InvalidData)}
    if($Lease.Outcome -ceq 'TimedOut'){
        if($Lease.Abandoned -or $null -ne $Lease.Handle -or $null -ne $Lease.OwnerManagedThreadId -or -not $Lease.Released){Throw-CcodKernelError 'CCOD_KERNEL_LEASE_INVALID' ([Management.Automation.ErrorCategory]::InvalidData)}
        return $false
    }
    if($Lease.Outcome -cne 'Acquired' -or $Lease.OwnerManagedThreadId -isnot [int] -or $Lease.OwnerManagedThreadId -le 0){Throw-CcodKernelError 'CCOD_KERNEL_LEASE_INVALID' ([Management.Automation.ErrorCategory]::InvalidData)}
    if($Lease.Released){if($null -ne $Lease.Handle){Throw-CcodKernelError 'CCOD_KERNEL_LEASE_INVALID' ([Management.Automation.ErrorCategory]::InvalidData)};return $false}
    if($Lease.Handle -isnot [Threading.Mutex]){Throw-CcodKernelError 'CCOD_KERNEL_LEASE_INVALID' ([Management.Automation.ErrorCategory]::InvalidData)}
    if([Threading.Thread]::CurrentThread.ManagedThreadId -ne $Lease.OwnerManagedThreadId){Throw-CcodKernelError 'CCOD_KERNEL_RELEASE_FAILED' ([Management.Automation.ErrorCategory]::InvalidOperation)}
    try{$Lease.Handle.ReleaseMutex()}catch{Throw-CcodKernelError 'CCOD_KERNEL_RELEASE_FAILED' ([Management.Automation.ErrorCategory]::InvalidOperation)}
    $handle=$Lease.Handle
    $Lease.Handle=$null;$Lease.Released=$true
    try{$handle.Dispose()}catch{Throw-CcodKernelError 'CCOD_KERNEL_RELEASE_FAILED' ([Management.Automation.ErrorCategory]::CloseError)}
    return $true
}

function New-CcodEventResult {
    param($Name,$Kind,$CreatedNew,$Handle)
    [pscustomobject][ordered]@{SchemaVersion=1;Name=$Name;Kind=$Kind;CreatedNew=[bool]$CreatedNew;Handle=$Handle;Disposed=$false}
}

function New-CcodEvent {
    [CmdletBinding()]
    param($Kind,$UserSid,$SessionId,$ReadyToken,$Adapters)
    if($Kind -isnot [string] -or @('Shutdown','Ready') -cnotcontains $Kind){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    $hasSession=$PSBoundParameters.ContainsKey('SessionId');$hasToken=$PSBoundParameters.ContainsKey('ReadyToken');$adapter=Get-CcodKernelAdapters $Adapters
    $name=Resolve-CcodKernelName $Kind $UserSid $SessionId $ReadyToken $hasSession $hasToken $adapter
    $security=New-CcodEventSecurity -UserSid $UserSid;$handle=$null
    try{
        try{$opened=& $adapter.CreateEvent $name $security}catch [UnauthorizedAccessException]{Throw-CcodKernelError 'CCOD_KERNEL_ACCESS_DENIED' ([Management.Automation.ErrorCategory]::SecurityError)}catch [Threading.WaitHandleCannotBeOpenedException]{if(& $adapter.TestOtherMutexType $name){Throw-CcodKernelError 'CCOD_KERNEL_OBJECT_TYPE_MISMATCH' ([Management.Automation.ErrorCategory]::InvalidType)};Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::OpenError)}
        if($null -eq $opened -or $opened.Handle -isnot [Threading.EventWaitHandle] -or $opened.CreatedNew -isnot [bool]){Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::OpenError)}
        $handle=$opened.Handle;$actualSecurity=& $adapter.GetEventSecurity $handle;$descriptor=[byte[]]@(& $adapter.GetEventSecurityDescriptor $handle $actualSecurity);Assert-CcodKernelSecurity $actualSecurity $descriptor $UserSid ([Security.AccessControl.EventWaitHandleSecurity]) ([int][Security.AccessControl.EventWaitHandleRights]::FullControl)
        $result=New-CcodEventResult $name $Kind $opened.CreatedNew $handle;$handle=$null;return $result
    }catch{
        if($null -ne $handle){try{& $adapter.DisposeHandle $handle}catch{}}
        $fallback=if($_.Exception -is [UnauthorizedAccessException] -or $_.Exception -is [Security.SecurityException]){'CCOD_KERNEL_ACCESS_DENIED'}else{'CCOD_KERNEL_OPEN_FAILED'}
        Throw-CcodNormalizedKernelError $_ $fallback
    }
}

function Open-CcodEvent {
    [CmdletBinding()]
    param($Kind,$UserSid,$SessionId,$ReadyToken,$Adapters)
    if($Kind -isnot [string] -or @('Shutdown','Ready') -cnotcontains $Kind){Throw-CcodKernelError 'CCOD_KERNEL_INPUT_INVALID' ([Management.Automation.ErrorCategory]::InvalidArgument)}
    $hasSession=$PSBoundParameters.ContainsKey('SessionId');$hasToken=$PSBoundParameters.ContainsKey('ReadyToken');$adapter=Get-CcodKernelAdapters $Adapters
    $name=Resolve-CcodKernelName $Kind $UserSid $SessionId $ReadyToken $hasSession $hasToken $adapter;$handle=$null
    try{
        try{$handle=& $adapter.OpenEvent $name}catch [UnauthorizedAccessException]{Throw-CcodKernelError 'CCOD_KERNEL_ACCESS_DENIED' ([Management.Automation.ErrorCategory]::SecurityError)}catch [Threading.WaitHandleCannotBeOpenedException]{if(& $adapter.TestOtherMutexType $name){Throw-CcodKernelError 'CCOD_KERNEL_OBJECT_TYPE_MISMATCH' ([Management.Automation.ErrorCategory]::InvalidType)};Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::ObjectNotFound)}
        if($handle -isnot [Threading.EventWaitHandle]){Throw-CcodKernelError 'CCOD_KERNEL_OPEN_FAILED' ([Management.Automation.ErrorCategory]::OpenError)}
        $actualSecurity=& $adapter.GetEventSecurity $handle;$descriptor=[byte[]]@(& $adapter.GetEventSecurityDescriptor $handle $actualSecurity);Assert-CcodKernelSecurity $actualSecurity $descriptor $UserSid ([Security.AccessControl.EventWaitHandleSecurity]) ([int][Security.AccessControl.EventWaitHandleRights]::FullControl)
        $result=New-CcodEventResult $name $Kind $false $handle;$handle=$null;return $result
    }catch{
        if($null -ne $handle){try{& $adapter.DisposeHandle $handle}catch{}}
        $fallback=if($_.Exception -is [UnauthorizedAccessException] -or $_.Exception -is [Security.SecurityException]){'CCOD_KERNEL_ACCESS_DENIED'}else{'CCOD_KERNEL_OPEN_FAILED'}
        Throw-CcodNormalizedKernelError $_ $fallback
    }
}

Export-ModuleMember -Function Get-CcodKernelObjectName,New-CcodMutexSecurity,New-CcodEventSecurity,Enter-CcodMutex,Exit-CcodMutex,New-CcodEvent,Open-CcodEvent
