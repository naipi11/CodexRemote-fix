Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$assetContractPath = Join-Path $PSScriptRoot 'ReleaseAssetContract.psm1'
if (-not [IO.File]::Exists($assetContractPath)) { throw 'CCOD_RELEASE_ASSET_CONTRACT_MISSING' }
$script:CcodReleaseAssetContractModule = Import-Module $assetContractPath -Force -PassThru -ErrorAction Stop

function Throw-CcodReleaseDefenderError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidOperation,$Target)
}

function Assert-CcodReleaseDefenderPlainAncestry {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId,[switch]$AllowMissingLeaf)
    try {
        if([string]::IsNullOrWhiteSpace($Path)-or-not[IO.Path]::IsPathRooted($Path)){throw 'absolute'}
        $canonical=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetPathRoot($canonical);$full=if($canonical.Length-gt$root.Length){$canonical.TrimEnd('\')}else{$canonical};$presented=if($Path.Length-gt$root.Length){$Path.TrimEnd('\')}else{$Path}
        if($full-cne$presented-or$full.IndexOf(':',$full.IndexOf(':')+1)-ge0){throw 'canonical'}
        $current=if($AllowMissingLeaf){Split-Path $full -Parent}else{$full}
        while(-not[string]::IsNullOrWhiteSpace($current)){$item=Get-Item -LiteralPath $current -Force -ErrorAction Stop;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'reparse'};if($current.TrimEnd('\')-ceq$root.TrimEnd('\')){break};$parent=[IO.Directory]::GetParent($current);if($null-eq$parent){break};$current=if($parent.FullName.Length-gt$root.Length){$parent.FullName.TrimEnd('\')}else{$parent.FullName}}
        return $full
    } catch { Throw-CcodReleaseDefenderError $ErrorId 'Path is missing, noncanonical, or has unsafe ancestry.' $Path }
}

function Assert-CcodReleaseDefenderRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full=Assert-CcodReleaseDefenderPlainAncestry -Path $Path -ErrorId 'CCOD_RELEASE_ASSET_INVALID';try{$item=Get-Item -LiteralPath $full -Force -ErrorAction Stop}catch{Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind is missing" $full}
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be a regular non-reparse file" $full};return $full
}

function Assert-CcodReleaseDefenderEvidenceTarget {
    param([Parameter(Mandatory)][string]$Path)
    $target=Assert-CcodReleaseDefenderPlainAncestry -Path $Path -ErrorId 'CCOD_DEFENDER_EVIDENCE_INVALID' -AllowMissingLeaf
    if([IO.Path]::GetExtension($target)-cne'.json'-or[IO.File]::Exists($target)-or[IO.Directory]::Exists($target)){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_INVALID' 'Defender evidence must be a new canonical JSON leaf.' $target}
    try{$existing=Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue;if($null-ne$existing){throw 'existing'}}catch{Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_INVALID' 'Defender evidence target already exists or is unsafe.' $target};return $target
}

function Get-CcodReleaseDefenderDefaultAdapters {
    $assetModule=$script:CcodReleaseAssetContractModule
    return @{
        GetDefenderStatus={Get-MpComputerStatus -ErrorAction Stop}
        StartCustomScan={param($Path)Start-MpScan -ScanType CustomScan -ScanPath $Path -ErrorAction Stop}
        GetThreatDetections={@(Get-MpThreatDetection -ErrorAction Stop)}
        GetUtcNow={[datetime]::UtcNow}
        PublishReceiptBytes={param($Directory,$Leaf,$Bytes)&$assetModule {param($Directory,$Leaf,$Bytes)Publish-CcodReleaseReceiptAuthority -Directory $Directory -Leaf $Leaf -Bytes $Bytes -ErrorId 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'} $Directory $Leaf $Bytes}.GetNewClosure()
    }
}

function Resolve-CcodReleaseDefenderAdapters {
    param([hashtable]$Adapters)
    $resolved=Get-CcodReleaseDefenderDefaultAdapters;if($null-eq$Adapters){return $resolved}
    foreach($name in $Adapters.Keys){if(-not$resolved.ContainsKey([string]$name)-or$Adapters[$name]-isnot[scriptblock]){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ADAPTER_INVALID' 'Private Defender adapters must replace known scriptblock operations only.' $name};$resolved[[string]$name]=$Adapters[$name]};return $resolved
}

function Get-CcodReleaseDefenderDetectionKeys {
    param($Records)
    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($record in @($Records)){if($null-eq$record){continue};$threat=if($null-ne$record.PSObject.Properties['ThreatID']){[string]$record.ThreatID}else{''};$time=if($null-ne$record.PSObject.Properties['InitialDetectionTime']){[string]$record.InitialDetectionTime}else{''};$resources=if($null-ne$record.PSObject.Properties['Resources']){(@($record.Resources)-join'|')}else{''};if(-not[string]::IsNullOrWhiteSpace($threat)-or-not[string]::IsNullOrWhiteSpace($time)-or-not[string]::IsNullOrWhiteSpace($resources)){[void]$keys.Add("$threat|$time|$resources")}}
    Write-Output -NoEnumerate $keys
}

function Test-CcodReleaseDefenderPositiveInteger {
    param($Value)
    if($Value-is[bool]-or$Value-isnot[ValueType]){return $false};try{return [decimal]$Value-eq[decimal][uint64]$Value-and[uint64]$Value-gt0}catch{return $false}
}

function Assert-CcodReleaseDefenderOrigin {
    param([Parameter(Mandatory)][string]$Origin,$WorkflowArtifactIdentity,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    if($Origin-ceq'InternetDownload'){if($null-ne$WorkflowArtifactIdentity){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ORIGIN_INVALID' 'Internet-download evidence cannot claim a workflow artifact identity.' $WorkflowArtifactIdentity};return $null}
    if($Origin-cne'TrustedWorkflowArtifact'-or$null-eq$WorkflowArtifactIdentity-or$WorkflowArtifactIdentity-isnot[pscustomobject]-or(@($WorkflowArtifactIdentity.PSObject.Properties.Name)-join',')-cne'provider,repository,runId,runAttempt,artifactId,artifactName,artifactDigest,gitCommit'-or$WorkflowArtifactIdentity.provider-cne'GitHubActions'-or$WorkflowArtifactIdentity.repository-cne'naipi11/CodexRemote-fix'-or-not(Test-CcodReleaseDefenderPositiveInteger $WorkflowArtifactIdentity.runId)-or-not(Test-CcodReleaseDefenderPositiveInteger $WorkflowArtifactIdentity.runAttempt)-or-not(Test-CcodReleaseDefenderPositiveInteger $WorkflowArtifactIdentity.artifactId)-or$WorkflowArtifactIdentity.artifactName-cne'CodexRemote-fix portable bundle'-or$WorkflowArtifactIdentity.artifactDigest-cnotmatch'^sha256:[0-9a-f]{64}$'-or$WorkflowArtifactIdentity.gitCommit-cne$ExpectedGitCommit){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ORIGIN_INVALID' 'Trusted workflow evidence requires one exact GitHub Actions artifact identity.' $WorkflowArtifactIdentity}
    return [pscustomobject][ordered]@{provider=[string]$WorkflowArtifactIdentity.provider;repository=[string]$WorkflowArtifactIdentity.repository;runId=[uint64]$WorkflowArtifactIdentity.runId;runAttempt=[uint64]$WorkflowArtifactIdentity.runAttempt;artifactId=[uint64]$WorkflowArtifactIdentity.artifactId;artifactName=[string]$WorkflowArtifactIdentity.artifactName;artifactDigest=[string]$WorkflowArtifactIdentity.artifactDigest;gitCommit=[string]$WorkflowArtifactIdentity.gitCommit}
}

function Get-CcodReleaseDefenderStatusEvidence {
    param([Parameter(Mandatory)]$Status,[Parameter(Mandatory)][datetime]$ScanStarted)
    $required=@('AMServiceEnabled','AntivirusEnabled','RealTimeProtectionEnabled','AMProductVersion','AMEngineVersion','AntivirusSignatureVersion','AntivirusSignatureLastUpdated');if($null-eq$Status-or@($required|Where-Object{$null-eq$Status.PSObject.Properties[$_]}).Count-ne0-or$Status.AMServiceEnabled-isnot[bool]-or-not$Status.AMServiceEnabled-or$Status.AntivirusEnabled-isnot[bool]-or-not$Status.AntivirusEnabled-or$Status.RealTimeProtectionEnabled-isnot[bool]-or-not$Status.RealTimeProtectionEnabled-or$Status.AMProductVersion-isnot[string]-or[string]::IsNullOrWhiteSpace($Status.AMProductVersion)-or$Status.AMProductVersion.Length-gt128-or$Status.AMEngineVersion-isnot[string]-or[string]::IsNullOrWhiteSpace($Status.AMEngineVersion)-or$Status.AMEngineVersion.Length-gt128-or$Status.AntivirusSignatureVersion-isnot[string]-or[string]::IsNullOrWhiteSpace($Status.AntivirusSignatureVersion)-or$Status.AntivirusSignatureVersion.Length-gt128-or$Status.AntivirusSignatureLastUpdated-isnot[datetime]){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_STATUS_INVALID' 'Defender service, AV, real-time, platform, engine, or signature state is incomplete.' $Status}
    $signature=([datetime]$Status.AntivirusSignatureLastUpdated).ToUniversalTime();if($signature-lt$ScanStarted.AddHours(-72)-or$signature-gt$ScanStarted.AddMinutes(5)){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_STATUS_INVALID' 'Defender signature timestamp is stale or future-dated.' $signature}
    return [pscustomobject][ordered]@{ServiceEnabled=$true;AntivirusEnabled=$true;RealTimeProtectionEnabled=$true;PlatformVersion=[string]$Status.AMProductVersion;EngineVersion=[string]$Status.AMEngineVersion;SignatureVersion=[string]$Status.AntivirusSignatureVersion;SignatureUpdatedAtUtc=$signature.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
}

function Open-CcodReleaseDefenderHeldInputs {
    param([string]$CandidatePath,[string]$ChecksumPath,[string]$ManifestPath,[string]$EvidenceTarget,[string]$Origin)
    $assetModule=$script:CcodReleaseAssetContractModule;$candidateDirectory=$null;$candidate=$null;$checksum=$null;$manifest=$null;$zone=$null;$evidenceDirectory=$null
    try{
        $candidateFile=Assert-CcodReleaseDefenderRegularFile $CandidatePath 'Release candidate asset';$checksumFile=Assert-CcodReleaseDefenderRegularFile $ChecksumPath 'Release checksum';$manifestFile=Assert-CcodReleaseDefenderRegularFile $ManifestPath 'Release manifest';$directory=Split-Path $candidateFile -Parent
        if((Split-Path $checksumFile -Parent)-cne$directory-or(Split-Path $manifestFile -Parent)-cne$directory){Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Candidate, checksum, and manifest must be exact siblings.' $candidateFile}
        $candidateDirectory=&$assetModule {param($Path)Open-CcodReleaseDirectoryAuthority -Path $Path -ErrorId 'CCOD_RELEASE_ASSET_INVALID'} $directory
        $candidate=&$assetModule {param($Directory,$Leaf)Open-CcodReleaseFileAuthority -Directory $Directory -Leaf $Leaf -ErrorId 'CCOD_RELEASE_ASSET_INVALID' -AllowZone} $candidateDirectory ([IO.Path]::GetFileName($candidateFile));$checksum=&$assetModule {param($Directory,$Leaf)Open-CcodReleaseFileAuthority -Directory $Directory -Leaf $Leaf -ErrorId 'CCOD_RELEASE_ASSET_INVALID' -MaximumBytes 65536} $candidateDirectory ([IO.Path]::GetFileName($checksumFile));$manifest=&$assetModule {param($Directory,$Leaf)Open-CcodReleaseFileAuthority -Directory $Directory -Leaf $Leaf -ErrorId 'CCOD_RELEASE_ASSET_INVALID' -MaximumBytes 4194304} $candidateDirectory ([IO.Path]::GetFileName($manifestFile))
        if($Origin-ceq'InternetDownload'){$zone=&$assetModule {param($File)Open-CcodReleaseZoneAuthority -File $File -ErrorId 'CCOD_DEFENDER_ZONE_REQUIRED'} $candidate}
        $evidenceDirectory=&$assetModule {param($Path)Open-CcodReleaseDirectoryAuthority -Path $Path -ErrorId 'CCOD_DEFENDER_EVIDENCE_INVALID' -AllowChildMutation} (Split-Path $EvidenceTarget -Parent)
        return [pscustomobject]@{CandidateDirectory=$candidateDirectory;Candidate=$candidate;Checksum=$checksum;Manifest=$manifest;Zone=$zone;EvidenceDirectory=$evidenceDirectory;EvidenceTarget=$EvidenceTarget;Closed=$false}
    }catch{if($null-ne$zone){&$assetModule {param($Value)Close-CcodReleaseAuthority $Value} $zone};foreach($value in @($manifest,$checksum,$candidate,$evidenceDirectory,$candidateDirectory)){if($null-ne$value){&$assetModule {param($Value)Close-CcodReleaseAuthority $Value} $value}};throw}
}

function Close-CcodReleaseDefenderHeldInputs {
    param($Held)
    if($null-eq$Held-or$Held.Closed){return};$assetModule=$script:CcodReleaseAssetContractModule;foreach($value in @($Held.Zone,$Held.Manifest,$Held.Checksum,$Held.Candidate,$Held.EvidenceDirectory,$Held.CandidateDirectory)){if($null-ne$value){&$assetModule {param($Value)Close-CcodReleaseAuthority $Value} $value}};$Held.Closed=$true
}

function Assert-CcodReleaseDefenderHeldInputsCurrent {
    param([Parameter(Mandatory)]$Held)
    $assetModule=$script:CcodReleaseAssetContractModule;&$assetModule {param($Value)Assert-CcodReleaseAuthorityCurrent -Authority $Value -ErrorId 'CCOD_RELEASE_ASSET_HASH_MISMATCH'|Out-Null} $Held.CandidateDirectory
    foreach($value in @($Held.Candidate,$Held.Checksum,$Held.Manifest,$Held.Zone)){if($null-ne$value){&$assetModule {param($Value)Assert-CcodReleaseAuthorityCurrent -Authority $Value -ErrorId 'CCOD_RELEASE_ASSET_HASH_MISMATCH' -CheckBytes|Out-Null} $value}}
}

function Get-CcodReleaseDefenderPinnedBytes {
    param([Parameter(Mandatory)]$Authority,[long]$MaximumBytes=4194304)
    $assetModule=$script:CcodReleaseAssetContractModule;$bytes=&$assetModule {param($Value,$Maximum)Assert-CcodReleaseAuthorityCurrent -Authority $Value -ErrorId 'CCOD_RELEASE_ASSET_HASH_MISMATCH' -CheckBytes|Out-Null;Get-CcodReleaseAuthorityStreamBytes -Stream $Value.Stream -MaximumBytes $Maximum} $Authority $MaximumBytes;return ,([byte[]]$bytes)
}

function Get-CcodReleaseDefenderPinnedZoneId {
    param([Parameter(Mandatory)]$Zone)
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString((Get-CcodReleaseDefenderPinnedBytes $Zone 65536));$matches=[regex]::Matches($text,'(?im)^[ \t]*ZoneId[ \t]*=[ \t]*([0-9]+)[ \t]*\r?$');$value=0;if($matches.Count-ne1-or-not[int]::TryParse($matches[0].Groups[1].Value,[ref]$value)-or$value-ne3){throw 'zone'};return $value}catch{Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ZONE_REQUIRED' 'The held download Zone stream is not unique ZoneId 3.' $Zone.Path}
}

function Confirm-CcodReleaseDefenderReceiptReadback {
    param([Parameter(Mandatory)]$PublishedAuthority,[Parameter(Mandatory)]$ReadbackAuthority,[Parameter(Mandatory)][string]$ExpectedPath,[Parameter(Mandatory)][byte[]]$ExpectedBytes,[Parameter(Mandatory)]$ExpectedReceipt)
    $assetModule=$script:CcodReleaseAssetContractModule
    try{
        if($PublishedAuthority.Path-cne$ExpectedPath-or$ReadbackAuthority.Path-cne$ExpectedPath-or$PublishedAuthority.Identity.Volume-ne$ReadbackAuthority.Identity.Volume-or$PublishedAuthority.Identity.FileId-ne$ReadbackAuthority.Identity.FileId-or$PublishedAuthority.Length-ne$ReadbackAuthority.Length-or$PublishedAuthority.Sha256-cne$ReadbackAuthority.Sha256){throw 'identity'}
        &$assetModule {param($Value)Assert-CcodReleaseAuthorityCurrent -Authority $Value -ErrorId 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' -CheckBytes|Out-Null} $PublishedAuthority;$readback=&$assetModule {param($Value)Read-CcodReleaseContractPinnedJson -Authority $Value -ErrorId 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' -MaximumBytes 65536} $ReadbackAuthority
        if([Convert]::ToBase64String([byte[]]$readback.Bytes)-cne[Convert]::ToBase64String($ExpectedBytes)){throw 'bytes'};$fields='schemaVersion,assetType,assetName,assetSha256,checksumName,checksumSha256,manifestName,manifestSha256,version,gitCommit,origin,workflowArtifactIdentity,zoneId,defenderServiceEnabled,antivirusEnabled,realTimeProtectionEnabled,defenderPlatformVersion,defenderEngineVersion,signatureVersion,signatureUpdatedAtUtc,scanStartedAtUtc,scanCompletedAtUtc,detectionCount,outcome,errorCode';if((@($readback.Value.PSObject.Properties.Name)-join',')-cne$fields-or($readback.Value|ConvertTo-Json -Depth 12 -Compress)-cne($ExpectedReceipt|ConvertTo-Json -Depth 12 -Compress)){throw 'object'};return $readback.Value
    }catch{Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' 'Defender receipt durable read-back did not match.' $ExpectedPath}
}

function Invoke-CcodReleaseDefenderCheckCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CandidatePath,[Parameter(Mandatory)][string]$ChecksumPath,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$Origin,$WorkflowArtifactIdentity,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,[Parameter(Mandatory)][string]$EvidencePath,[hashtable]$Adapters)
    $adapters=Resolve-CcodReleaseDefenderAdapters $Adapters;$evidenceTarget=Assert-CcodReleaseDefenderEvidenceTarget $EvidencePath;$workflowIdentity=Assert-CcodReleaseDefenderOrigin $Origin $WorkflowArtifactIdentity $ExpectedGitCommit;$held=$null;$receiptAuthority=$null;$receiptReadbackAuthority=$null;$assetModule=$script:CcodReleaseAssetContractModule
    try{
        $held=Open-CcodReleaseDefenderHeldInputs $CandidatePath $ChecksumPath $ManifestPath $evidenceTarget $Origin;$candidateDirectory=$held.CandidateDirectory.Path;$candidateLeaf=$held.Candidate.Leaf;$names=@(Get-CcodExpectedReleaseAssetNames $ExpectedVersion);$assetType=if($candidateLeaf-ceq$names[5]){'Setup'}elseif($candidateLeaf-ceq$names[0]){'PortableZip'}else{$null};if($null-eq$assetType){Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Candidate is not the exact versioned Setup or portable ZIP asset.' $candidateLeaf};$checksumName=if($assetType-ceq'Setup'){$names[6]}else{$names[1]};$manifestName=if($assetType-ceq'Setup'){$names[10]}else{$names[4]};if($held.Checksum.Leaf-cne$checksumName-or$held.Manifest.Leaf-cne$manifestName){Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Checksum or manifest does not match the selected asset.' $candidateLeaf}
        $checksumText=[Text.UTF8Encoding]::new($false,$true).GetString((Get-CcodReleaseDefenderPinnedBytes $held.Checksum 65536)).TrimEnd("`r","`n");if($checksumText-cne("$($held.Candidate.Sha256) *$candidateLeaf")){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Held checksum does not bind candidate bytes.' $held.Checksum.Path};$manifest=Test-CcodReleaseAssetManifest $held.Manifest.Path $candidateDirectory $ExpectedVersion;if($manifest.GitCommit-cne$ExpectedGitCommit-or$manifest.InstallerName-cne$candidateLeaf-or$manifest.InstallerSha256-cne$held.Candidate.Sha256){Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Manifest, commit, and candidate identity differ.' $candidateLeaf}
        $zone=if($Origin-ceq'InternetDownload'){Get-CcodReleaseDefenderPinnedZoneId $held.Zone}else{$null};$started=&$adapters.GetUtcNow;if($started-isnot[datetime]){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender start clock is invalid.' $started};$started=([datetime]$started).ToUniversalTime();$status=Get-CcodReleaseDefenderStatusEvidence (&$adapters.GetDefenderStatus) $started;$before=Get-CcodReleaseDefenderDetectionKeys (&$adapters.GetThreatDetections);$scanError=$null;try{&$adapters.StartCustomScan $held.Candidate.Path}catch{$scanError=$_};$completed=&$adapters.GetUtcNow;if($completed-isnot[datetime]){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender completion clock is invalid.' $completed};$completed=([datetime]$completed).ToUniversalTime();if($completed-lt$started-or$completed-gt$started.AddHours(2)){Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender scan clock is reversed or too long.' $completed};$after=Get-CcodReleaseDefenderDetectionKeys (&$adapters.GetThreatDetections);$detections=@($after|Where-Object{-not$before.Contains($_)})
        Assert-CcodReleaseDefenderHeldInputsCurrent $held;$revalidated=Test-CcodReleaseAssetManifest $held.Manifest.Path $candidateDirectory $ExpectedVersion;if($revalidated.GitCommit-cne$ExpectedGitCommit-or$revalidated.InstallerSha256-cne$held.Candidate.Sha256){Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Held identity changed during scan.' $candidateLeaf};if($Origin-ceq'InternetDownload'){[void](Get-CcodReleaseDefenderPinnedZoneId $held.Zone)};$errorCode=if($null-ne$scanError){'CCOD_DEFENDER_SCAN_FAILED'}elseif($detections.Count-gt0){'CCOD_DEFENDER_DETECTIONS_FOUND'}else{$null}
        $receipt=[pscustomobject][ordered]@{schemaVersion=2;assetType=$assetType;assetName=$candidateLeaf;assetSha256=$held.Candidate.Sha256;checksumName=$checksumName;checksumSha256=$held.Checksum.Sha256;manifestName=$manifestName;manifestSha256=$held.Manifest.Sha256;version=$ExpectedVersion;gitCommit=$ExpectedGitCommit;origin=$Origin;workflowArtifactIdentity=$workflowIdentity;zoneId=$zone;defenderServiceEnabled=[bool]$status.ServiceEnabled;antivirusEnabled=[bool]$status.AntivirusEnabled;realTimeProtectionEnabled=[bool]$status.RealTimeProtectionEnabled;defenderPlatformVersion=[string]$status.PlatformVersion;defenderEngineVersion=[string]$status.EngineVersion;signatureVersion=[string]$status.SignatureVersion;signatureUpdatedAtUtc=[string]$status.SignatureUpdatedAtUtc;scanStartedAtUtc=$started.ToString('o',[Globalization.CultureInfo]::InvariantCulture);scanCompletedAtUtc=$completed.ToString('o',[Globalization.CultureInfo]::InvariantCulture);detectionCount=[int]$detections.Count;outcome=if($null-eq$errorCode){'Completed'}else{'Failed'};errorCode=$errorCode};$bytes=[Text.UTF8Encoding]::new($false).GetBytes((($receipt|ConvertTo-Json -Depth 12)+[Environment]::NewLine))
        try{$receiptAuthority=&$adapters.PublishReceiptBytes $held.EvidenceDirectory ([IO.Path]::GetFileName($evidenceTarget)) $bytes;$children=[Collections.Generic.List[string]]::new();foreach($name in @($held.EvidenceDirectory.Children)){$children.Add([string]$name)};$children.Add([IO.Path]::GetFileName($evidenceTarget));$ordered=[string[]]@($children);[Array]::Sort($ordered,[StringComparer]::Ordinal);$held.EvidenceDirectory.Children=$ordered;&$assetModule {param($Value)Assert-CcodReleaseAuthorityCurrent -Authority $Value -ErrorId 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'|Out-Null} $held.EvidenceDirectory;$receiptReadbackAuthority=&$assetModule {param($Directory,$Leaf)Open-CcodReleaseFileAuthority -Directory $Directory -Leaf $Leaf -ErrorId 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' -MaximumBytes 65536 -ShareDelete} $held.EvidenceDirectory ([IO.Path]::GetFileName($evidenceTarget));[void](Confirm-CcodReleaseDefenderReceiptReadback $receiptAuthority $receiptReadbackAuthority $evidenceTarget $bytes $receipt)}catch{$detail=$_.Exception.Message;foreach($value in @($receiptReadbackAuthority,$receiptAuthority)){if($null-ne$value){&$assetModule {param($Value)Close-CcodReleaseAuthority $Value} $value}};$receiptReadbackAuthority=$null;$receiptAuthority=$null;Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' ('Defender receipt could not be durably read back: '+$detail) $evidenceTarget}
        Assert-CcodReleaseDefenderHeldInputsCurrent $held;if($null-ne$errorCode){Throw-CcodReleaseDefenderError $errorCode 'The Defender final-asset gate did not complete cleanly.' $held.Candidate.Sha256};return $receipt
    }finally{foreach($value in @($receiptReadbackAuthority,$receiptAuthority)){if($null-ne$value){&$assetModule {param($Value)Close-CcodReleaseAuthority $Value} $value}};Close-CcodReleaseDefenderHeldInputs $held}
}

function Invoke-CcodReleaseDefenderCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CandidatePath,[Parameter(Mandatory)][string]$ChecksumPath,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][ValidateSet('TrustedWorkflowArtifact','InternetDownload')][string]$Origin,$WorkflowArtifactIdentity,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,[Parameter(Mandatory)][string]$EvidencePath)
    Invoke-CcodReleaseDefenderCheckCore $CandidatePath $ChecksumPath $ManifestPath $Origin $WorkflowArtifactIdentity $ExpectedVersion $ExpectedGitCommit $EvidencePath $null
}

Export-ModuleMember -Function Invoke-CcodReleaseDefenderCheck
