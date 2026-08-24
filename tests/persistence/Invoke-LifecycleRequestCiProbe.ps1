$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleRequest.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force

function Write-CcodLifecycleCiProbeFact {
    param([string]$Name,$Value)
    [Console]::Out.WriteLine(('CCOD_LIFECYCLE_CI_PROBE {0}={1}' -f $Name,$Value))
}

function Write-CcodLifecycleCiProbeAclFacts {
    param([string]$Inbox)
    Write-CcodLifecycleCiProbeFact 'inboxExists' ([IO.Directory]::Exists($Inbox))
    if (-not [IO.Directory]::Exists($Inbox)) { return }
    try {
        $item=Get-Item -LiteralPath $Inbox -Force -ErrorAction Stop
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $security=[IO.Directory]::GetAccessControl($Inbox)
            $owner=$security.GetOwner([Security.Principal.SecurityIdentifier])
            $rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            $expected=@($identity.User.Value,'S-1-5-18','S-1-5-32-544')
            $allowlisted=@($rules | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl -and $expected -ccontains $_.IdentityReference.Value }).Count
            Write-CcodLifecycleCiProbeFact 'inboxDirectory' $item.PSIsContainer
            Write-CcodLifecycleCiProbeFact 'inboxReparse' (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            Write-CcodLifecycleCiProbeFact 'aclOwnerCurrent' ($null -ne $owner -and $owner.Value -ceq $identity.User.Value)
            Write-CcodLifecycleCiProbeFact 'aclProtected' $security.AreAccessRulesProtected
            Write-CcodLifecycleCiProbeFact 'aclRuleCount' $rules.Count
            Write-CcodLifecycleCiProbeFact 'aclAllowlistedFullControl' $allowlisted
            Write-CcodLifecycleCiProbeFact 'aclInheritedRuleCount' @($rules | Where-Object { $_.IsInherited }).Count
        } finally { $identity.Dispose() }
    } catch {
        Write-CcodLifecycleCiProbeFact 'aclProbeError' (([string]$_.FullyQualifiedErrorId -split ',')[0])
    }
}

function Write-CcodLifecycleCiProbeFileAclFacts {
    param([string]$Path)
    Write-CcodLifecycleCiProbeFact 'requestExists' ([IO.File]::Exists($Path))
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $security=[IO.File]::GetAccessControl($Path)
            $owner=$security.GetOwner([Security.Principal.SecurityIdentifier])
            $rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            $expected=@($identity.User.Value,'S-1-5-18','S-1-5-32-544')
            $allowlisted=@($rules | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl -and $expected -ccontains $_.IdentityReference.Value }).Count
            Write-CcodLifecycleCiProbeFact 'requestAclOwnerCurrent' ($null -ne $owner -and $owner.Value -ceq $identity.User.Value)
            Write-CcodLifecycleCiProbeFact 'requestAclProtected' $security.AreAccessRulesProtected
            Write-CcodLifecycleCiProbeFact 'requestAclRuleCount' $rules.Count
            Write-CcodLifecycleCiProbeFact 'requestAclAllowlistedFullControl' $allowlisted
            Write-CcodLifecycleCiProbeFact 'requestAclInheritedRuleCount' @($rules | Where-Object { $_.IsInherited }).Count
        } finally { $identity.Dispose() }
    } catch {
        Write-CcodLifecycleCiProbeFact 'requestAclProbeError' (([string]$_.FullyQualifiedErrorId -split ',')[0])
    }
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-lifecycle-ci-probe-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory((Join-Path $root 'state\lifecycle')) | Out-Null
    $submissionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $transactionId='11111111-2222-3333-4444-555555555555'
    $timestamp='2030-02-03T04:05:06.0000000Z'
    $event=[pscustomobject]@{Disposed=$false}
    $onSignal={
        param($StateRoot)
        $submission=Receive-CcodLifecycleSubmissions -StateRoot $StateRoot -MaximumCount 1
        Write-CcodLifecycleSubmissionReceipt -StateRoot $StateRoot -SubmissionId $submission.submissionId -Accepted $true -TransactionId $transactionId -ErrorCode $null -Adapters @{GetUtcNow={ [DateTime]::ParseExact($timestamp,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }.GetNewClosure()} | Out-Null
    }.GetNewClosure()
    $adapters=@{
        NewGuid={ [guid]::Parse($submissionId) }.GetNewClosure()
        GetUtcNow={ [DateTime]::ParseExact($timestamp,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) }.GetNewClosure()
        OpenWakeEvent={param($UserSid,$SessionId)$event}.GetNewClosure()
        SignalWakeEvent={param($Handle)& $onSignal (Join-Path $root 'state')}.GetNewClosure()
        DisposeWakeEvent={param($Handle)$Handle.Disposed=$true}.GetNewClosure()
        Sleep={param($Milliseconds)}
    }
    $receipt=Submit-CcodLifecycleRequest -InstallRoot ([IO.Path]::GetFullPath($root)) -Kind RestartAndRepair -Origin Installer -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 5000 -Adapters $adapters
    Write-CcodLifecycleCiProbeFact 'host' ($PSVersionTable.PSEdition + ':' + $PSVersionTable.PSVersion)
    Write-CcodLifecycleCiProbeFact 'accepted' $receipt.accepted
    Write-CcodLifecycleCiProbeFact 'errorCode' $receipt.errorCode
    $inbox=Join-Path $root 'state\lifecycle\inbox'
    Write-CcodLifecycleCiProbeAclFacts -Inbox $inbox
    $requestPath=Join-Path $inbox ($submissionId + '.request.json')
    Write-CcodLifecycleCiProbeFileAclFacts -Path $requestPath
    Write-CcodLifecycleCiProbeFact 'receiptCount' @((Get-ChildItem -LiteralPath $inbox -Filter '*.receipt.json' -File -ErrorAction SilentlyContinue)).Count
} catch {
    Write-CcodLifecycleCiProbeFact 'exception' (([string]$_.FullyQualifiedErrorId -split ',')[0])
} finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) }
}
