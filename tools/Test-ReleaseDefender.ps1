[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidatePath,
    [Parameter(Mandatory)][string]$ChecksumPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidateSet('TrustedWorkflowArtifact','InternetDownload')][string]$Origin,
    $WorkflowArtifactIdentity,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,
    [Parameter(Mandatory)][string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'ReleaseDefender.psm1'
if (-not [IO.File]::Exists($modulePath)) { Write-Error 'CCOD_RELEASE_DEFENDER_MODULE_MISSING'; exit 1 }

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Invoke-CcodReleaseDefenderCheck -CandidatePath $CandidatePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -Origin $Origin -WorkflowArtifactIdentity $WorkflowArtifactIdentity -ExpectedVersion $ExpectedVersion -ExpectedGitCommit $ExpectedGitCommit -EvidencePath $EvidencePath | ConvertTo-Json -Depth 12
} catch {
    Write-Error $_
    exit 1
}
