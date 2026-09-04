Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CcodDraftReleaseAssetContractModule = $null

function Throw-CcodGitHubDraftError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target)
}

function Test-CcodGitHubDraftSchemaVersion($Value) {
    return ($Value -is [int] -or $Value -is [long]) -and [long]$Value -eq 1
}

function Test-CcodGitHubDraftCanonicalAbsolutePath($Path) {
    if ([string]::IsNullOrWhiteSpace([string]$Path)) { return $false }
    try {
        if (-not [IO.Path]::IsPathRooted([string]$Path)) { return $false }
        $full = [IO.Path]::GetFullPath([string]$Path)
        return [string]::Equals($full, [string]$Path, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Import-CcodDraftReleaseAssetContract {
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $candidates.Add((Join-Path $PSScriptRoot 'ReleaseAssetContract.psm1')) }
    $candidates.Add((Join-Path (Get-Location) 'tools\ReleaseAssetContract.psm1'))
    foreach ($path in $candidates) {
        if ([IO.File]::Exists($path)) {
            $script:CcodDraftReleaseAssetContractModule = Import-Module $path -Force -DisableNameChecking -PassThru
            return
        }
    }
    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING' 'Release asset contract module is missing.' $null
}

function Read-CcodGitHubDraftContractJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId)
    if ($null -eq $script:CcodDraftReleaseAssetContractModule) { Import-CcodDraftReleaseAssetContract }
    try {
        return & $script:CcodDraftReleaseAssetContractModule { param($JsonPath,$ContractErrorId) Read-CcodReleaseContractJson -Path $JsonPath -ErrorId $ContractErrorId } $Path $ErrorId
    } catch {
        Throw-CcodGitHubDraftError $ErrorId 'Draft evidence JSON is malformed or outside its contract.' $Path
    }
}

function Read-CcodGitHubDraftPreflight {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$GitCommit)
    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING' 'Stage requires transferred clean-runner preflight evidence.' $Path
    }
    $Path = Assert-CcodGitHubDraftPlainPath -Path $Path -Directory $false
    $parsed = Read-CcodGitHubDraftContractJson -Path $Path -ErrorId 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID'
    $record = $parsed.Value
    $fields = @($record.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'schemaVersion,valid,version,gitCommit,repositoryRoot' -or
        -not (Test-CcodGitHubDraftSchemaVersion $record.schemaVersion) -or
        $record.valid -isnot [bool] -or -not [bool]$record.valid -or
        $record.version -isnot [string] -or $record.version -cne $Version -or
        $record.gitCommit -isnot [string] -or $record.gitCommit -cne $GitCommit -or
        $record.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $record.repositoryRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($record.repositoryRoot) -or
        -not (Test-CcodGitHubDraftCanonicalAbsolutePath $record.repositoryRoot)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID' 'Transferred clean-runner preflight is not bound to this candidate.' $Path
    }
    return $record
}

function Assert-CcodGitHubDraftRemoteView {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,$View,[switch]$AfterPromotion)
    $notStagedId = if ($AfterPromotion) { 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' } else { 'CCOD_GITHUB_DRAFT_NOT_STAGED' }
    if ($null -eq $View -or $View -isnot [pscustomobject]) {
        Throw-CcodGitHubDraftError $notStagedId 'GitHub returned no structured release state.' $Tag
    }
    $fields = @($View.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'Tag,Draft,AssetNames' -or $View.Tag -isnot [string] -or $View.Tag -cne $Tag -or $View.Draft -isnot [bool]) {
        Throw-CcodGitHubDraftError $notStagedId 'GitHub release state has an invalid schema.' $Tag
    }
    if ((-not $AfterPromotion -and -not [bool]$View.Draft) -or ($AfterPromotion -and [bool]$View.Draft)) {
        Throw-CcodGitHubDraftError $notStagedId 'The GitHub release has an invalid draft visibility state.' $Tag
    }
    $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    $actual = @($View.AssetNames)
    if ($actual.Count -ne $expected.Count) {
        Throw-CcodGitHubDraftError $notStagedId 'GitHub draft does not contain the complete release asset set.' $Tag
    }
    if ((($actual | ForEach-Object { [string]$_ }) -join "`n") -cne ($expected -join "`n")) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_SET_INVALID' 'GitHub draft assets are not the exact ordered release set.' $Tag
    }
    return [string[]]$actual
}

function Assert-CcodGitHubDraftPrivateView {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,$View)
    if ($null -eq $View -or $View -isnot [pscustomobject]) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'GitHub returned no structured private draft state.' $Tag
    }
    $fields = @($View.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'Tag,Draft,AssetNames' -or $View.Tag -isnot [string] -or $View.Tag -cne $Tag -or $View.Draft -isnot [bool] -or -not [bool]$View.Draft -or $null -eq $View.AssetNames) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'GitHub returned an invalid or non-private draft state.' $Tag
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @(Get-CcodExpectedReleaseAssetNames -Version $Version)) { [void]$expected.Add($name) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($View.AssetNames)) {
        if ($name -isnot [string] -or -not $expected.Contains([string]$name) -or -not $seen.Add([string]$name)) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_SET_INVALID' 'Private draft contains an unexpected or duplicate asset.' $Tag
        }
    }
    [string[]]$seen
}

$script:CcodGitHubDraftStageLocks = @{}

function Get-CcodGitHubDraftStageLockName([string]$Tag) {
    "Local\CodexRemoteFix.Release.Stage.$Tag"
}

function Acquire-CcodGitHubDraftStageLock {
    param([Parameter(Mandatory)][string]$Tag)
    if ($script:CcodGitHubDraftStageLocks.ContainsKey($Tag)) { return $false }
    $mutex = $null
    try {
        $mutex = [Threading.Mutex]::new($false, (Get-CcodGitHubDraftStageLockName $Tag))
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            return $false
        }
        $script:CcodGitHubDraftStageLocks[$Tag] = $mutex
        return $true
    } catch {
        if ($null -ne $mutex) { $mutex.Dispose() }
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_LOCK_FAILED' 'Could not inspect or acquire the same-tag draft lock.' $Tag
    }
}

function Release-CcodGitHubDraftStageLock {
    param([Parameter(Mandatory)][string]$Tag)
    if (-not $script:CcodGitHubDraftStageLocks.ContainsKey($Tag)) { return }
    $mutex = $script:CcodGitHubDraftStageLocks[$Tag]
    $script:CcodGitHubDraftStageLocks.Remove($Tag)
    try {
        $mutex.ReleaseMutex()
    } finally {
        $mutex.Dispose()
    }
}

function Assert-CcodGitHubDraftActionsContext {
    param([Parameter(Mandatory)][string]$Tag)
    $repository = 'naipi11/CodexRemote-fix'
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_SERVER_URL -cne 'https://github.com' -or $env:GITHUB_REPOSITORY -cne $repository -or $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_GH_FORBIDDEN' 'GitHub draft adapters require the official CodexRemote-fix Actions context.' $Tag
    }
}

function Assert-CcodGitHubDraftAuthenticatedContext {
    param([Parameter(Mandatory)][string]$Tag)
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { return }
    try {
        & gh auth status '--hostname' 'github.com' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'gh auth status failed' }
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_GH_FORBIDDEN' 'Draft readback requires an authenticated GitHub CLI context.' $Tag
    }
}

function Get-CcodGitHubDraftTagCommit {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][bool]$ActionsOnly)
    if ($ActionsOnly) { Assert-CcodGitHubDraftActionsContext $Tag } else { Assert-CcodGitHubDraftAuthenticatedContext $Tag }
    $endpoint = 'repos/naipi11/CodexRemote-fix/commits/' + $Tag
    $lines = @(& gh api $endpoint '--jq' '.sha')
    if ($LASTEXITCODE -ne 0) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED' 'Could not resolve the official remote tag commit.' $Tag
    }
    $commit = (($lines | ForEach-Object { [string]$_ }) -join '').Trim().ToLowerInvariant()
    if ($commit -notmatch '^[0-9a-f]{40}\z') {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED' 'GitHub returned an invalid remote tag commit.' $Tag
    }
    $commit
}

function Assert-CcodGitHubDraftTagCommit {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$ExpectedCommit,[Parameter(Mandatory)]$Adapters,[Parameter(Mandatory)][bool]$ActionsOnly)
    if ($ExpectedCommit -notmatch '^[0-9a-f]{40}\z') {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_INVALID' 'Candidate commit is not canonical.' $ExpectedCommit
    }
    try {
        $actualCommit = ([string](& $Adapters.GetTagCommit $Tag $ActionsOnly)).Trim().ToLowerInvariant()
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED' 'Could not read the remote tag commit.' $Tag
    }
    if ($actualCommit -cne $ExpectedCommit.ToLowerInvariant()) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_MISMATCH' 'Remote tag does not resolve to the immutable candidate commit.' $Tag
    }
}

function Get-CcodGitHubDraftReleaseDefaultAdapters {
    @{
        TryStageLock = {
            param($Tag)
            Acquire-CcodGitHubDraftStageLock $Tag
        }
        AcquireStageLock = {
            param($Tag)
            Acquire-CcodGitHubDraftStageLock $Tag
        }
        ReleaseStageLock = {
            param($Tag)
            Release-CcodGitHubDraftStageLock $Tag
        }
        CreateDraft = {
            param($Tag, $Title, $Notes)
            Assert-CcodGitHubDraftActionsContext $Tag
            & gh release create $Tag '--repo' 'naipi11/CodexRemote-fix' '--draft' '--verify-tag' '--title' $Title '--notes' $Notes | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Could not create a private draft.' $Tag }
            [pscustomobject]@{ Tag = $Tag; Draft = $true }
        }
        UploadAsset = {
            param($Tag, $Name, $Path)
            Assert-CcodGitHubDraftActionsContext $Tag
            & gh release upload $Tag '--repo' 'naipi11/CodexRemote-fix' $Path | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED' 'Could not upload a draft asset.' $Name }
        }
        GetTagCommit = {
            param($Tag, [bool]$ActionsOnly)
            Get-CcodGitHubDraftTagCommit -Tag $Tag -ActionsOnly $ActionsOnly
        }
        DownloadAsset = {
            param($Tag, $Name, $Destination)
            Assert-CcodGitHubDraftAuthenticatedContext $Tag
            $dir = [IO.Path]::GetDirectoryName($Destination)
            & gh release download $Tag '--repo' 'naipi11/CodexRemote-fix' '--pattern' $Name '--dir' $dir | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_READBACK_FAILED' 'Could not read back a staged draft asset.' $Name }
        }
        ViewRelease = {
            param($Tag)
            Assert-CcodGitHubDraftAuthenticatedContext $Tag
            $json = & gh release view $Tag '--repo' 'naipi11/CodexRemote-fix' '--json' 'isDraft,assets'
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'Could not read the GitHub draft state.' $Tag }
            try {
                $value = ($json -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
                $fields = @($value.PSObject.Properties.Name)
                if ($null -eq $value -or $fields.Count -ne 2 -or $fields -notcontains 'isDraft' -or $fields -notcontains 'assets' -or $value.isDraft -isnot [bool] -or $null -eq $value.assets) { throw 'schema' }
                $assetNames = [Collections.Generic.List[string]]::new()
                foreach ($asset in @($value.assets)) {
                    if ($null -eq $asset -or $null -eq $asset.PSObject.Properties['name'] -or $asset.name -isnot [string] -or [string]::IsNullOrWhiteSpace($asset.name)) { throw 'asset schema' }
                    $assetNames.Add([string]$asset.name)
                }
                [pscustomobject]@{ Tag = $Tag; Draft = $value.isDraft; AssetNames = [string[]]$assetNames }
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'GitHub returned malformed release state.' $Tag
            }
        }
        SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            Assert-CcodGitHubDraftAuthenticatedContext $Tag
            if ($Draft) { & gh release edit $Tag '--repo' 'naipi11/CodexRemote-fix' '--draft' | Out-Null } else { & gh release edit $Tag '--repo' 'naipi11/CodexRemote-fix' '--draft=false' | Out-Null }
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_FAILED' 'Could not change draft visibility.' $Tag }
        }
        InvokeBuild = {
            param($Version)
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_REBUILD' 'Draft promotion cannot rebuild a candidate.' $Version
        }
        InvokeGh = {
            param($Arguments)
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_GH_FORBIDDEN' 'Raw gh invocation is not part of the draft contract.' $Arguments
        }
    }
}

function Resolve-CcodGitHubDraftReleaseAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodGitHubDraftReleaseDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in @($Adapters.Keys)) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ADAPTER_INVALID' 'Private draft adapters must replace known scriptblock operations only.' $name
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Get-CcodGitHubDraftFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function New-CcodGitHubDraftFrozenAssetSet {
    param([Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)]$Contract)
    $frozenDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-frozen-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($frozenDirectory) | Out-Null
        $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
        $contractAssets = @($Contract.Assets)
        if ($contractAssets.Count -ne $expected.Count) { throw 'candidate contract asset count' }
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $name = $expected[$index]
            if ($contractAssets[$index].name -isnot [string] -or [string]$contractAssets[$index].name -cne $name -or $contractAssets[$index].sha256 -isnot [string] -or [string]$contractAssets[$index].sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'candidate contract asset identity' }
            $source = Join-Path $AssetDirectory $name
            $destination = Join-Path $frozenDirectory $name
            [IO.File]::Copy($source, $destination, $false)
            if ((Get-CcodGitHubDraftFileSha256 $destination) -cne [string]$contractAssets[$index].sha256) { throw 'candidate changed during freeze' }
        }
        return [pscustomobject][ordered]@{ Directory = $frozenDirectory; Names = [string[]]$expected; GitCommit = [string]$Contract.GitCommit }
    } catch {
        if ([IO.Directory]::Exists($frozenDirectory)) { Remove-Item -LiteralPath $frozenDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'The release candidate changed or could not be frozen.' $AssetDirectory
    }
}

function Remove-CcodGitHubDraftFrozenAssetSet {
    param($Frozen)
    if ($null -ne $Frozen -and [string]::IsNullOrWhiteSpace([string]$Frozen.Directory) -eq $false -and [IO.Directory]::Exists([string]$Frozen.Directory)) {
        Remove-Item -LiteralPath ([string]$Frozen.Directory) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CcodGitHubDraftDownloadAsset {
    param([Parameter(Mandatory)][hashtable]$Adapters,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$ErrorId)
    try {
        & $Adapters.DownloadAsset $Tag $Name $Destination
        if (-not [IO.File]::Exists($Destination)) { throw 'download did not create destination' }
    } catch {
        Throw-CcodGitHubDraftError $ErrorId 'GitHub asset readback failed.' $Name
    }
}

function Get-CcodGitHubDraftPreflightName([string]$Version) {
    "CodexRemote-fix-$Version-clean-preflight.json"
}

function Get-CcodGitHubDraftAcceptanceName([string]$Version) {
    "CodexRemote-fix-$Version-official-draft.complete.json"
}

function Get-CcodGitHubDraftVerificationName([string]$Version) {
    "CodexRemote-fix-$Version-draft-verified.json"
}

function Get-CcodGitHubDraftDefenderEvidenceDirectory([string]$EvidenceDirectory) {
    $dedicated = Join-Path $EvidenceDirectory 'defender'
    if ([IO.File]::Exists($dedicated)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'The Defender evidence plane is not a directory.' $dedicated
    }
    if ([IO.Directory]::Exists($dedicated)) {
        return Assert-CcodGitHubDraftPlainPath -Path $dedicated -Directory $true
    }
    return Assert-CcodGitHubDraftPlainPath -Path $EvidenceDirectory -Directory $true
}

function Assert-CcodGitHubDraftPlainPath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][bool]$Directory)
    if ($null -eq $script:CcodDraftReleaseAssetContractModule) { Import-CcodDraftReleaseAssetContract }
    try {
        return & $script:CcodDraftReleaseAssetContractModule { param($Value,$IsDirectory) Assert-CcodReleaseContractPlainPath -Path $Value -Directory $IsDirectory -ErrorId 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' } $Path $Directory
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence path is missing, noncanonical, or has unsafe reparse ancestry.' $Path
    }
}

function Get-CcodGitHubDraftEvidencePlanePath {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][ValidateSet('verification','acceptance')][string]$Plane,[switch]$Create)
    $root = Assert-CcodGitHubDraftPlainPath -Path $EvidenceDirectory -Directory $true
    $path = Join-Path $root $Plane
    if ([IO.File]::Exists($path)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence plane is a file, not a directory.' $path
    }
    if (-not [IO.Directory]::Exists($path)) {
        if (-not $Create) { return $path }
        try { [IO.Directory]::CreateDirectory($path) | Out-Null } catch { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence plane could not be created safely.' $path }
    }
    return Assert-CcodGitHubDraftPlainPath -Path $path -Directory $true
}

function Get-CcodGitHubDraftEvidenceFilePath {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][ValidateSet('verification','acceptance')][string]$Plane,[Parameter(Mandatory)][string]$Leaf,[switch]$CreatePlane)
    $planePath = Get-CcodGitHubDraftEvidencePlanePath -EvidenceDirectory $EvidenceDirectory -Plane $Plane -Create:$CreatePlane
    $path = Join-Path $planePath $Leaf
    if ([IO.Directory]::Exists($path)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target is a directory, not a file.' $path
    }
    if ([IO.File]::Exists($path)) { return Assert-CcodGitHubDraftPlainPath -Path $path -Directory $false }
    if ([IO.Path]::GetFullPath($path) -cne $path) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target is not canonical.' $path
    }
    return $path
}

function Get-CcodGitHubDraftRootEvidenceFilePath([string]$EvidenceDirectory,[string]$Leaf) {
    $root = Assert-CcodGitHubDraftPlainPath -Path $EvidenceDirectory -Directory $true
    $path = Join-Path $root $Leaf
    if ([IO.Directory]::Exists($path)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target is a directory, not a file.' $path
    }
    if ([IO.File]::Exists($path)) { return Assert-CcodGitHubDraftPlainPath -Path $path -Directory $false }
    return $path
}

function Get-CcodGitHubDraftVerificationPath([string]$EvidenceDirectory,[string]$Version,[switch]$CreatePlane) {
    Get-CcodGitHubDraftEvidenceFilePath -EvidenceDirectory $EvidenceDirectory -Plane verification -Leaf (Get-CcodGitHubDraftVerificationName $Version) -CreatePlane:$CreatePlane
}

function Get-CcodGitHubDraftAcceptancePath([string]$EvidenceDirectory,[string]$Version) {
    Get-CcodGitHubDraftEvidenceFilePath -EvidenceDirectory $EvidenceDirectory -Plane acceptance -Leaf (Get-CcodGitHubDraftAcceptanceName $Version)
}

function Write-CcodGitHubDraftJsonCreateOnly {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string]$ErrorId)
    $Path = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($Path)
    [void](Assert-CcodGitHubDraftPlainPath -Path $directory -Directory $true)
    if ([IO.Directory]::Exists($Path)) { Throw-CcodGitHubDraftError $ErrorId 'Draft evidence target is a directory, not a file.' $Path }
    if ([IO.File]::Exists($Path)) { [void](Assert-CcodGitHubDraftPlainPath -Path $Path -Directory $false) }
    $json = (($Record | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($json)
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } catch {
        Throw-CcodGitHubDraftError $ErrorId 'Draft evidence is not create-only or could not be published.' $Path
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if (-not [IO.File]::Exists($Path)) { Throw-CcodGitHubDraftError $ErrorId 'Draft evidence write did not produce a file.' $Path }
}

function Read-CcodGitHubDraftVerification {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$GitCommit)
    $path = Get-CcodGitHubDraftVerificationPath $EvidenceDirectory $Version
    if (-not [IO.File]::Exists($path)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_MISSING' 'Promote requires a persisted successful Verify record.' $path }
    $record = (Read-CcodGitHubDraftContractJson -Path $path -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID').Value
    $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    $fields = @($record.PSObject.Properties.Name)
    $hashes = @($record.assetSha256)
    $names = @($record.assetNames)
    $localManifest = Join-Path $AssetDirectory (Get-CcodGitHubDraftManifestName $Version)
    if ($record -isnot [pscustomobject] -or ($fields -join ',') -cne 'schemaVersion,kind,tag,version,gitCommit,draft,verified,assetNames,assetSha256,candidateManifestSha256' -or
        -not (Test-CcodGitHubDraftSchemaVersion $record.schemaVersion) -or
        $record.kind -isnot [string] -or $record.kind -cne 'github-draft-verification' -or $record.tag -isnot [string] -or $record.tag -cne $Tag -or
        $record.version -isnot [string] -or $record.version -cne $Version -or $record.gitCommit -isnot [string] -or $record.gitCommit -cne $GitCommit -or
        $record.draft -isnot [bool] -or -not [bool]$record.draft -or
        $record.verified -isnot [bool] -or -not [bool]$record.verified -or
        $names.Count -ne $expected.Count -or (@($names | Where-Object { $_ -isnot [string] }).Count -ne 0) -or (($names | ForEach-Object { [string]$_ }) -join "`n") -cne ($expected -join "`n") -or
        $hashes.Count -ne $expected.Count -or (@($hashes | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[0-9a-f]{64}$' }).Count -ne 0) -or
        $record.candidateManifestSha256 -isnot [string] -or $record.candidateManifestSha256 -cne (Get-CcodGitHubDraftFileSha256 $localManifest)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'Persisted Verify evidence is not bound to the exact candidate.' $path
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ([string]$hashes[$index] -cne (Get-CcodGitHubDraftFileSha256 (Join-Path $AssetDirectory $expected[$index]))) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'Persisted Verify asset hashes do not match the candidate.' $path
        }
    }
    return $record
}

function Get-CcodGitHubDraftManifestName([string]$Version) {
    "CodexRemote-fix-$Version-release-manifest.json"
}

function Read-CcodGitHubDraftAcceptance {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$GitCommit)
    $path = Get-CcodGitHubDraftAcceptancePath $EvidenceDirectory $Version
    if (-not [IO.File]::Exists($path)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_MISSING' 'Promotion requires Task 8/9 official-draft acceptance evidence.' $path }
    $record = (Read-CcodGitHubDraftContractJson -Path $path -ErrorId 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID').Value
    $fields = @($record.PSObject.Properties.Name)
    $manifestPath = Join-Path $AssetDirectory (Get-CcodGitHubDraftManifestName $Version)
    $canonicalCompletedAtUtc = $null
    try {
        $parsedCompletedAtUtc = [DateTimeOffset]::ParseExact([string]$record.completedAtUtc, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $canonicalCompletedAtUtc = $parsedCompletedAtUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    } catch { }
    if ($record -isnot [pscustomobject] -or ($fields -join ',') -cne 'schemaVersion,kind,version,gitCommit,candidateManifestSha256,phase,completedAtUtc' -or
        -not (Test-CcodGitHubDraftSchemaVersion $record.schemaVersion) -or $record.kind -isnot [string] -or $record.kind -cne 'official-draft-acceptance' -or
        $record.version -isnot [string] -or $record.version -cne $Version -or $record.gitCommit -isnot [string] -or $record.gitCommit -cne $GitCommit -or $record.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $record.candidateManifestSha256 -isnot [string] -or $record.candidateManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $record.candidateManifestSha256 -cne (Get-CcodGitHubDraftFileSha256 $manifestPath) -or
        $record.phase -isnot [string] -or $record.phase -cne 'Complete' -or $record.completedAtUtc -isnot [string] -or [string]$record.completedAtUtc -cne $canonicalCompletedAtUtc) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Official-draft acceptance evidence is malformed or not bound to this candidate.' $path
    }
    return $record
}

function Invoke-CcodGitHubDraftReleaseCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Stage','Verify','Promote')][string]$Mode,
        [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+\z')][string]$Tag,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [string]$NotesPath,
        [hashtable]$Adapters
    )
    $Mode = if ($Mode -ieq 'Stage') { 'Stage' } elseif ($Mode -ieq 'Verify') { 'Verify' } elseif ($Mode -ieq 'Promote') { 'Promote' } else { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_MODE_INVALID' 'Release mode is invalid.' $Mode }
    $adapters = Resolve-CcodGitHubDraftReleaseAdapters $Adapters
    $version = $Tag.Substring(1)
    $assetDir = [IO.Path]::GetFullPath($AssetDirectory)
    $evidenceDir = [IO.Path]::GetFullPath($EvidenceDirectory)
    Import-CcodDraftReleaseAssetContract
    $evidenceDir = Assert-CcodGitHubDraftPlainPath -Path $evidenceDir -Directory $true
    if ($Mode -ceq 'Promote') {
        $promoteLockHeld = $false
        try {
            if ($null -eq $Adapters) {
                $promoteLockHeld = [bool](& $adapters.AcquireStageLock $Tag)
            } else {
                $promoteLockHeld = [bool](& $adapters.TryStageLock $Tag)
            }
            if (-not $promoteLockHeld) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CONCURRENT' 'Same-tag release operation is already running.' $Tag
            }
            $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
            Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
            $preflight = Join-Path $evidenceDir (Get-CcodGitHubDraftPreflightName $version)
            Read-CcodGitHubDraftPreflight -Path $preflight -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
            $frozen = New-CcodGitHubDraftFrozenAssetSet -AssetDirectory $assetDir -Version $version -Contract $assets
            try {
                $frozenDirectory = [string]$frozen.Directory
                $defenderEvidence = Get-CcodGitHubDraftDefenderEvidenceDirectory $evidenceDir
                try {
                    Test-CcodReleasePromotionEvidence -EvidenceDirectory $defenderEvidence -AssetDirectory $frozenDirectory -Version $version -ExpectedGitCommit $assets.GitCommit | Out-Null
                } catch {
                    $id = ([string]$_.FullyQualifiedErrorId -split '[,:]')[0]
                    if ($id -ceq 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID' -or $id -ceq 'CCOD_RELEASE_ASSET_SET_INVALID') { throw }
                    Throw-CcodGitHubDraftError 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID' 'Promotion requires Task 5 dual InternetDownload receipts.' $defenderEvidence
                }
                Read-CcodGitHubDraftAcceptance -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
                $verification = Read-CcodGitHubDraftVerification -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit)
                try {
                    $view = & $adapters.ViewRelease $Tag
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'Could not read the already verified GitHub draft state.' $Tag
                }
                $expected = @(Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $view)
                $readRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-promote-' + [guid]::NewGuid().ToString('N'))
                [IO.Directory]::CreateDirectory($readRoot) | Out-Null
                try {
                    for ($index = 0; $index -lt $expected.Count; $index++) {
                        $name = $expected[$index]
                        $destination = Join-Path $readRoot $name
                        Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
                        $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                        if ($actualHash -cne [string]$verification.assetSha256[$index] -or $actualHash -cne (Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name))) {
                            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Verified draft asset changed before promotion.' $name
                        }
                    }
                } finally {
                    if ([IO.Directory]::Exists($readRoot)) { Remove-Item -LiteralPath $readRoot -Recurse -Force -ErrorAction SilentlyContinue }
                }
                try {
                    $beforePublishView = & $adapters.ViewRelease $Tag
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Could not re-read the private draft before promotion.' $Tag
                }
                [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $beforePublishView)
                Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
                try {
                    & $adapters.SetReleaseDraftState $Tag $false
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_FAILED' 'Could not change draft visibility.' $Tag
                }
                try {
                    $postView = & $adapters.ViewRelease $Tag
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Could not read the final GitHub release state.' $Tag
                }
                [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $postView -AfterPromotion)
                Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
                $postReadRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-post-promote-' + [guid]::NewGuid().ToString('N'))
                [IO.Directory]::CreateDirectory($postReadRoot) | Out-Null
                try {
                    for ($index = 0; $index -lt $expected.Count; $index++) {
                        $name = $expected[$index]
                        $destination = Join-Path $postReadRoot $name
                        Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED'
                        $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                        if ($actualHash -cne [string]$verification.assetSha256[$index] -or $actualHash -cne (Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name))) {
                            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Public release asset changed after promotion.' $name
                        }
                    }
                } finally {
                    if ([IO.Directory]::Exists($postReadRoot)) { Remove-Item -LiteralPath $postReadRoot -Recurse -Force -ErrorAction SilentlyContinue }
                }
                return [pscustomobject][ordered]@{ Mode = $Mode; Tag = $Tag; Draft = $false; Promoted = $true }
            } finally {
                Remove-CcodGitHubDraftFrozenAssetSet $frozen
            }
        } finally {
            if ($promoteLockHeld) {
                & $adapters.ReleaseStageLock $Tag
            }
        }
    }
    $defaultLockHeld = $false
    try {
        if ($null -eq $Adapters) {
            $defaultLockHeld = [bool](& $adapters.AcquireStageLock $Tag)
        } else {
            $defaultLockHeld = [bool](& $adapters.TryStageLock $Tag)
        }
        if (-not $defaultLockHeld) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CONCURRENT' 'Same-tag Stage is already running.' $Tag
        }
        $preflight = Join-Path $evidenceDir (Get-CcodGitHubDraftPreflightName $version)
    $assets = $null
    if ($Mode -ceq 'Stage') {
        if (-not [IO.File]::Exists($preflight)) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING' 'Stage requires transferred clean-runner preflight evidence.' $preflight
        }
        $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
        Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
        Read-CcodGitHubDraftPreflight -Path $preflight -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
    }
    if ($Mode -ceq 'Verify') {
        $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
        Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
        Read-CcodGitHubDraftPreflight -Path $preflight -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
        $frozen = New-CcodGitHubDraftFrozenAssetSet -AssetDirectory $assetDir -Version $version -Contract $assets
        try {
            $frozenDirectory = [string]$frozen.Directory
            try {
                $view = & $adapters.ViewRelease $Tag
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'Could not read the staged GitHub draft state.' $Tag
            }
            $expected = @(Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $view)
            $readRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-verify-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($readRoot) | Out-Null
            try {
                foreach ($name in $expected) {
                    $destination = Join-Path $readRoot $name
                    Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
                    $expectedHash = Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name)
                    $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                    if ($expectedHash -cne $actualHash) {
                        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_READBACK_FAILED' 'Verified draft asset hash does not match the frozen candidate.' $name
                    }
                }
            } finally {
                if ([IO.Directory]::Exists($readRoot)) { Remove-Item -LiteralPath $readRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
            $verificationHashes = [Collections.Generic.List[string]]::new()
            foreach ($name in $expected) { $verificationHashes.Add((Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name))) }
            $verificationRecord = [ordered]@{
                schemaVersion = 1
                kind = 'github-draft-verification'
                tag = $Tag
                version = $version
                gitCommit = [string]$assets.GitCommit
                draft = $true
                verified = $true
                assetNames = [string[]]$expected
                assetSha256 = [string[]]$verificationHashes
                candidateManifestSha256 = Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory (Get-CcodGitHubDraftManifestName $version))
            }
            $verificationPath = Get-CcodGitHubDraftVerificationPath $evidenceDir $version -CreatePlane
            Write-CcodGitHubDraftJsonCreateOnly -Path $verificationPath -Record $verificationRecord -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID'
            Read-CcodGitHubDraftVerification -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
            return [pscustomobject][ordered]@{ Mode = $Mode; Tag = $Tag; Draft = $true; Verified = $true; VerificationPath = $verificationPath }
        } finally {
            Remove-CcodGitHubDraftFrozenAssetSet $frozen
        }
    }
    $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
    $frozen = New-CcodGitHubDraftFrozenAssetSet -AssetDirectory $assetDir -Version $version -Contract $assets
    try {
        $frozenDirectory = [string]$frozen.Directory
        $notes = ''
        if (-not [string]::IsNullOrWhiteSpace($NotesPath)) {
            $notesFile = [IO.Path]::GetFullPath($NotesPath)
            try {
                $notesItem = Get-Item -LiteralPath $notesFile -Force -ErrorAction Stop
                if (-not $notesItem.PSIsContainer -and $notesItem.Length -le 1048576) {
                    $notes = [IO.File]::ReadAllText($notesFile, [Text.UTF8Encoding]::new($false, $true))
                } else { throw 'notes bounds' }
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOTES_INVALID' 'Release notes are missing, invalid, or too large.' $notesFile
            }
        }
        $expected = [string[]]$frozen.Names
        $created = $false
        try {
            $createdResult = & $adapters.CreateDraft $Tag ("CodexRemote-fix $version") $notes
            if ($null -eq $createdResult -or $createdResult -isnot [pscustomobject] -or @($createdResult.PSObject.Properties.Name) -join ',' -cne 'Tag,Draft' -or $createdResult.Tag -cne $Tag -or $createdResult.Draft -isnot [bool] -or -not [bool]$createdResult.Draft) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Draft creation did not return a private draft state.' $Tag
            }
            $created = $true
            Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
            $createdView = & $adapters.ViewRelease $Tag
            [void](Assert-CcodGitHubDraftPrivateView -Tag $Tag -Version $version -View $createdView)
            foreach ($name in $expected) {
                Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
                $beforeUploadView = & $adapters.ViewRelease $Tag
                [void](Assert-CcodGitHubDraftPrivateView -Tag $Tag -Version $version -View $beforeUploadView)
                & $adapters.UploadAsset $Tag $name (Join-Path $frozenDirectory $name)
            }
            $stageView = & $adapters.ViewRelease $Tag
            [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $stageView)
        } catch {
            if ($created) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED' 'Draft upload failed; the draft remains private.' $Tag
            }
            throw
        }
        $readRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-stage-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($readRoot) | Out-Null
        try {
            foreach ($name in $expected) {
                $destination = Join-Path $readRoot $name
                Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
                $expectedHash = Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name)
                $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                if ($expectedHash -cne $actualHash) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_READBACK_FAILED' 'Staged draft asset hash does not match the frozen candidate.' $name
                }
            }
        } finally {
            if ([IO.Directory]::Exists($readRoot)) { Remove-Item -LiteralPath $readRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
        return [pscustomobject][ordered]@{ Mode = $Mode; Tag = $Tag; Draft = $true; Uploaded = $expected }
    } finally {
        Remove-CcodGitHubDraftFrozenAssetSet $frozen
    }
    } finally {
        if ($null -eq $Adapters -and $defaultLockHeld) {
            & $adapters.ReleaseStageLock $Tag
        }
    }
}

function Invoke-CcodGitHubDraftRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Stage','Verify','Promote')][string]$Mode,
        [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+\z')][string]$Tag,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [string]$NotesPath
    )
    Invoke-CcodGitHubDraftReleaseCore -Mode $Mode -Tag $Tag -AssetDirectory $AssetDirectory -EvidenceDirectory $EvidenceDirectory -NotesPath $NotesPath
}

Export-ModuleMember -Function Invoke-CcodGitHubDraftRelease
