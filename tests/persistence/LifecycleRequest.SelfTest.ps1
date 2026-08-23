$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\LifecycleRequest.psm1'
$persistencePath = Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1'
Import-Module $modulePath -Force
Import-Module $persistencePath -Force

$requestFields = 'schemaVersion,submissionId,kind,origin,runtimeId,runtimeGeneration,createdAtUtc'
$receiptFields = 'schemaVersion,submissionId,accepted,transactionId,errorCode,completedAtUtc'
$timestamp = '2030-02-03T04:05:06.0000000Z'

function New-CcodLifecycleRequestTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-lifecycle-inbox-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory((Join-Path $root 'state\lifecycle')) | Out-Null
    return [IO.Path]::GetFullPath($root)
}

function Remove-CcodLifecycleRequestTestRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathRooted($Root)) { return }
    $full = [IO.Path]::GetFullPath($Root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^ccod-lifecycle-inbox-[0-9a-f]{32}$') {
        throw 'CCOD_TEST_CLEANUP_PATH_INVALID'
    }
    if ([IO.Directory]::Exists($full)) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function New-CcodSubmissionRecord {
    param(
        [string]$SubmissionId,
        [string]$Kind = 'RestartAndRepair',
        [string]$Origin = 'Installer',
        [string]$RuntimeId = '2.5.0-a',
        [UInt64]$RuntimeGeneration = 7,
        [string]$CreatedAtUtc = $timestamp
    )
    [pscustomobject][ordered]@{
        schemaVersion=1;submissionId=$SubmissionId;kind=$Kind;origin=$Origin;runtimeId=$RuntimeId
        runtimeGeneration=$RuntimeGeneration;createdAtUtc=$CreatedAtUtc
    }
}

function New-CcodSubmissionAdapters {
    param([string]$SubmissionId,[scriptblock]$OnSignal,[switch]$OpenFails,[switch]$SignalFails)
    $event = [pscustomobject]@{ Disposed=$false }
    @{
        NewGuid={ [guid]::Parse($SubmissionId) }.GetNewClosure()
        GetUtcNow={ [DateTime]::ParseExact($timestamp,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }.GetNewClosure()
        OpenWakeEvent={
            param($UserSid,$SessionId)
            if($OpenFails){throw 'wake event is unavailable'}
            return $event
        }.GetNewClosure()
        SignalWakeEvent={
            param($Handle)
            if($SignalFails){throw 'wake signal failed'}
            if($null -ne $OnSignal){& $OnSignal}
        }.GetNewClosure()
        DisposeWakeEvent={param($Handle)$Handle.Disposed=$true}.GetNewClosure()
        Sleep={param($Milliseconds)Start-Sleep -Milliseconds ([Math]::Max(1,[Math]::Min(5,[int]$Milliseconds)))}
    }
}

function Assert-CcodSubmissionReceipt {
    param($Receipt,[string]$SubmissionId,[bool]$Accepted,[AllowNull()]$TransactionId,[AllowNull()]$ErrorCode)
    Assert-CcodEqual $receiptFields (@($Receipt.PSObject.Properties.Name)-join ',') 'submission receipt fields are exact and ordered'
    Assert-CcodEqual 1 $Receipt.schemaVersion 'submission receipt schema'
    Assert-CcodEqual $SubmissionId $Receipt.submissionId 'submission receipt correlation'
    Assert-CcodEqual $ErrorCode $Receipt.errorCode 'submission error code'
    Assert-CcodEqual $Accepted $Receipt.accepted 'submission receipt acceptance'
    Assert-CcodEqual $TransactionId $Receipt.transactionId 'submission transaction correlation'
    Assert-CcodEqual $timestamp $Receipt.completedAtUtc 'submission receipt time is canonical and deterministic'
}

$results = [Collections.Generic.List[object]]::new()

$results.Add((Invoke-CcodTest 'submits one durable request and returns only its correlated accepted receipt without controller mutation' {
    $root=New-CcodLifecycleRequestTestRoot
    try{
        $submissionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $transactionId='11111111-2222-3333-4444-555555555555'
        $controllerCalls=0
        $onSignal={
            $submission=Receive-CcodLifecycleSubmissions -StateRoot (Join-Path $root 'state') -MaximumCount 1
            Assert-CcodEqual $requestFields (@($submission.PSObject.Properties.Name)-join ',') 'durable inbox request shape'
            Write-CcodLifecycleSubmissionReceipt -StateRoot (Join-Path $root 'state') -SubmissionId $submission.submissionId -Accepted $true -TransactionId $transactionId -ErrorCode $null -Adapters @{GetUtcNow={ [DateTime]::ParseExact($timestamp,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }.GetNewClosure()}
        }.GetNewClosure()
        $submitted=Submit-CcodLifecycleRequest -InstallRoot $root -Kind RestartAndRepair -Origin Installer -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 5000 -Adapters (New-CcodSubmissionAdapters $submissionId $onSignal)
        Assert-CcodSubmissionReceipt $submitted $submissionId $true $transactionId $null
        Assert-CcodEqual 0 $controllerCalls 'submitter never runs controller recovery or apply'
        $inbox=Join-Path $root 'state\lifecycle\inbox'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $inbox -Filter '*.request.json' -File).Count 'consumed request file is removed after receipt persistence'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $inbox -Filter '*.receipt.json' -File).Count 'one correlated receipt remains durable'
    }finally{Remove-CcodLifecycleRequestTestRoot $root}
}))

$results.Add((Invoke-CcodTest 'bounds the inbox at eight pending direct-child submissions and rejects a duplicate submission id' {
    $root=New-CcodLifecycleRequestTestRoot
    try{
        $firstId='00000000-0000-0000-0000-000000000001'
        $first=Submit-CcodLifecycleRequest -InstallRoot $root -Kind CheckAndRepair -Origin Tray -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 20 -Adapters (New-CcodSubmissionAdapters $firstId $null -OpenFails)
        Assert-CcodSubmissionReceipt $first $firstId $false $null 'CCOD_LIFECYCLE_SUPERVISOR_UNAVAILABLE'
        $duplicate=Submit-CcodLifecycleRequest -InstallRoot $root -Kind CheckAndRepair -Origin Tray -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 20 -Adapters (New-CcodSubmissionAdapters $firstId $null)
        Assert-CcodSubmissionReceipt $duplicate $firstId $false $null 'CCOD_LIFECYCLE_SUBMISSION_DUPLICATE'
        $inbox=Join-Path $root 'state\lifecycle\inbox'
        foreach($index in 2..8){
            $id=('00000000-0000-0000-0000-{0:D12}' -f $index)
            Write-CcodAtomicJsonIfAbsent -Path (Join-Path $inbox ($id+'.request.json')) -Value (New-CcodSubmissionRecord $id)
        }
        $ninthId='00000000-0000-0000-0000-000000000009'
        $ninth=Submit-CcodLifecycleRequest -InstallRoot $root -Kind RestartAndRepair -Origin Installer -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 20 -Adapters (New-CcodSubmissionAdapters $ninthId $null)
        Assert-CcodSubmissionReceipt $ninth $ninthId $false $null 'CCOD_LIFECYCLE_INBOX_FULL'
        Assert-CcodEqual 8 @(Get-ChildItem -LiteralPath $inbox -Filter '*.request.json' -File).Count 'ninth request is never persisted'
    }finally{Remove-CcodLifecycleRequestTestRoot $root}
}))

$results.Add((Invoke-CcodTest 'returns bounded failures for unavailable Supervisor wake failure timeout and stale receipt' {
    foreach($case in @(
        [pscustomobject]@{Id='10000000-0000-0000-0000-000000000001';Open=$true;Signal=$false;Stale=$false;Code='CCOD_LIFECYCLE_SUPERVISOR_UNAVAILABLE'},
        [pscustomobject]@{Id='10000000-0000-0000-0000-000000000002';Open=$false;Signal=$true;Stale=$false;Code='CCOD_LIFECYCLE_WAKE_FAILED'},
        [pscustomobject]@{Id='10000000-0000-0000-0000-000000000003';Open=$false;Signal=$false;Stale=$false;Code='CCOD_LIFECYCLE_SUBMISSION_TIMEOUT'},
        [pscustomobject]@{Id='10000000-0000-0000-0000-000000000004';Open=$false;Signal=$false;Stale=$true;Code='CCOD_LIFECYCLE_SUBMISSION_TIMEOUT'}
    )){
        $root=New-CcodLifecycleRequestTestRoot
        try{
            if($case.Stale){
                $inbox=Join-Path $root 'state\lifecycle\inbox';[IO.Directory]::CreateDirectory($inbox)|Out-Null
                $stale=[pscustomobject][ordered]@{schemaVersion=1;submissionId=$case.Id;accepted=$true;transactionId='11111111-2222-3333-4444-555555555555';errorCode=$null;completedAtUtc='2029-02-03T04:05:06.0000000Z'}
                Write-CcodAtomicJson -Path (Join-Path $inbox ($case.Id+'.receipt.json')) -Value $stale
            }
            $parameters=@{InstallRoot=$root;Kind='CheckAndRepair';Origin='Tray';RuntimeId='2.5.0-a';RuntimeGeneration=[UInt64]7;TimeoutMilliseconds=20}
            $adapters=New-CcodSubmissionAdapters $case.Id $null -OpenFails:$case.Open -SignalFails:$case.Signal
            $actual=Submit-CcodLifecycleRequest @parameters -Adapters $adapters
            Assert-CcodSubmissionReceipt $actual $case.Id $false $null $case.Code
        }finally{Remove-CcodLifecycleRequestTestRoot $root}
    }
}))

$results.Add((Invoke-CcodTest 'preserves Supervisor runtime and generation rejection and busy rejection as exact receipts' {
    foreach($case in @(
        [pscustomobject]@{Id='20000000-0000-0000-0000-000000000001';Code='CCOD_LIFECYCLE_RUNTIME_STALE'},
        [pscustomobject]@{Id='20000000-0000-0000-0000-000000000002';Code='CCOD_LIFECYCLE_SUPERVISOR_BUSY'}
    )){
        $root=New-CcodLifecycleRequestTestRoot
        try{
            $onSignal={
                $submission=Receive-CcodLifecycleSubmissions -StateRoot (Join-Path $root 'state') -MaximumCount 1
                Write-CcodLifecycleSubmissionReceipt -StateRoot (Join-Path $root 'state') -SubmissionId $submission.submissionId -Accepted $false -TransactionId $null -ErrorCode $case.Code -Adapters @{GetUtcNow={ [DateTime]::ParseExact($timestamp,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }.GetNewClosure()}
            }.GetNewClosure()
            $actual=Submit-CcodLifecycleRequest -InstallRoot $root -Kind RestartAndRepair -Origin Installer -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 5000 -Adapters (New-CcodSubmissionAdapters $case.Id $onSignal)
            Assert-CcodSubmissionReceipt $actual $case.Id $false $null $case.Code
        }finally{Remove-CcodLifecycleRequestTestRoot $root}
    }
}))

$results.Add((Invoke-CcodTest 'protects the current-user inbox ACL and rejects a lifecycle reparse ancestor' {
    $root=New-CcodLifecycleRequestTestRoot
    try{
        $id='30000000-0000-0000-0000-000000000001'
        [void](Submit-CcodLifecycleRequest -InstallRoot $root -Kind CheckAndRepair -Origin Tray -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 20 -Adapters (New-CcodSubmissionAdapters $id $null -OpenFails))
        $inbox=Join-Path $root 'state\lifecycle\inbox'
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{
            $security=[IO.Directory]::GetAccessControl($inbox)
            $owner=$security.GetOwner([Security.Principal.SecurityIdentifier])
            $rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            Assert-CcodEqual $identity.User.Value $owner.Value 'inbox owner is the current user'
            Assert-CcodTrue $security.AreAccessRulesProtected 'inbox inheritance is disabled'
            Assert-CcodEqual 3 $rules.Count 'inbox ACL has only current user SYSTEM and Administrators'
            $expected=@($identity.User.Value,'S-1-5-18','S-1-5-32-544')
            foreach($rule in $rules){
                Assert-CcodTrue ($expected -ccontains $rule.IdentityReference.Value) 'inbox ACL principal is allowlisted'
                Assert-CcodEqual ([Security.AccessControl.AccessControlType]::Allow) $rule.AccessControlType 'inbox ACL contains only allows'
                Assert-CcodEqual ([Security.AccessControl.FileSystemRights]::FullControl) $rule.FileSystemRights 'inbox ACL grants exact full control'
            }
        }finally{$identity.Dispose()}
        $directoryLeaf=Join-Path $inbox '30000000-0000-0000-0000-000000000099.request.json'
        [IO.Directory]::CreateDirectory($directoryLeaf)|Out-Null
        $directoryRejected=Submit-CcodLifecycleRequest -InstallRoot $root -Kind CheckAndRepair -Origin Tray -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 20 -Adapters (New-CcodSubmissionAdapters '30000000-0000-0000-0000-000000000003' $null)
        Assert-CcodSubmissionReceipt $directoryRejected '30000000-0000-0000-0000-000000000003' $false $null 'CCOD_LIFECYCLE_PATH_INVALID'
        Remove-Item -LiteralPath $directoryLeaf -Force
    }finally{Remove-CcodLifecycleRequestTestRoot $root}

    $root=New-CcodLifecycleRequestTestRoot;$outside=New-CcodLifecycleRequestTestRoot
    try{
        Remove-Item -LiteralPath (Join-Path $root 'state\lifecycle') -Recurse -Force
        New-Item -ItemType Junction -Path (Join-Path $root 'state\lifecycle') -Target (Join-Path $outside 'state\lifecycle') | Out-Null
        $rejected=Submit-CcodLifecycleRequest -InstallRoot $root -Kind CheckAndRepair -Origin Tray -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 20 -Adapters (New-CcodSubmissionAdapters '30000000-0000-0000-0000-000000000002' $null)
        Assert-CcodSubmissionReceipt $rejected '30000000-0000-0000-0000-000000000002' $false $null 'CCOD_LIFECYCLE_PATH_INVALID'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $outside 'state\lifecycle') -Filter '*.request.json' -Recurse -File).Count 'reparse target is never mutated'
    }finally{Remove-CcodLifecycleRequestTestRoot $root;Remove-CcodLifecycleRequestTestRoot $outside}
}))

$results | Format-Table -AutoSize
Write-Host ('Lifecycle request self-test passed: {0}' -f $results.Count)
