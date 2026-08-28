Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Throw-CcodSetupArtifactError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodSetupArtifactHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Test-CcodSetupCanonicalUtc {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Get-CcodSetupDescription {
    param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version)
    return "CCODSETUP $Version"
}

function Assert-CcodSetupRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { Throw-CcodSetupArtifactError 'CCOD_SETUP_ARTIFACT_INVALID' "$Kind is missing" $full }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_ARTIFACT_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    return $full
}

function Test-CcodSetupArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SetupPath,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPayloadManifestSha256
    )

    $setup = Assert-CcodSetupRegularFile -Path $SetupPath -Kind 'Setup artifact'
    $expectedPeVersion = "$ExpectedVersion.0"
    $expectedDescription = Get-CcodSetupDescription -Version $ExpectedVersion
    try { $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setup) }
    catch { Throw-CcodSetupArtifactError 'CCOD_SETUP_PE_VERSION_INVALID' 'Setup PE version metadata could not be read' $setup }
    $fileVersion = ([string]$versionInfo.FileVersion).Trim()
    $productVersion = ([string]$versionInfo.ProductVersion).Trim()
    $productName = ([string]$versionInfo.ProductName).Trim()
    $fileDescription = ([string]$versionInfo.FileDescription).Trim()
    $companyName = ([string]$versionInfo.CompanyName).Trim()
    $legalCopyright = ([string]$versionInfo.LegalCopyright).Trim()
    if ($fileVersion -cne $expectedPeVersion -or $productVersion -cne $expectedPeVersion) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PE_VERSION_INVALID' ("Setup PE FileVersion/ProductVersion do not match the release version: file={0}; product={1}; expected={2}" -f [string]$versionInfo.FileVersion,[string]$versionInfo.ProductVersion,$expectedPeVersion) $setup
    }
    if ($productName -cne 'CodexRemote-fix' -or $fileDescription -cne $expectedDescription -or
        $companyName -cne $ExpectedGitCommit -or $legalCopyright -cne $ExpectedPayloadManifestSha256) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PAYLOAD_BINDING_INVALID' ("Setup PE does not bind the expected version, commit, and activation payload manifest hash: product={0}; description={1}; company={2}; copyright={3}" -f $productName,$fileDescription,$companyName,$legalCopyright) $setup
    }
    return [pscustomobject][ordered]@{
        Valid = $true
        Sha256 = Get-CcodSetupArtifactHash -Path $setup
        FileVersion = $fileVersion
        ProductVersion = $productVersion
        ProductName = $productName
        FileDescription = $fileDescription
        CompanyName = $companyName
        LegalCopyright = $legalCopyright
    }
}

function New-CcodSetupBuildProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$GitCommit,
        [Parameter(Mandatory)][string]$BuildTimestampUtc,
        [Parameter(Mandatory)][string]$PayloadManifestPath,
        [Parameter(Mandatory)][string]$InnoTemplatePath,
        [Parameter(Mandatory)][string]$DestinationInventoryPath,
        [Parameter(Mandatory)][string]$CompilerPath,
        [Parameter(Mandatory)][string]$OutputPath
    )

    if (-not (Test-CcodSetupCanonicalUtc $BuildTimestampUtc)) { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Setup provenance timestamp is not canonical UTC' $BuildTimestampUtc }
    $payload = Assert-CcodSetupRegularFile -Path $PayloadManifestPath -Kind 'Installer payload manifest'
    $template = Assert-CcodSetupRegularFile -Path $InnoTemplatePath -Kind 'Inno template'
    $inventory = Assert-CcodSetupRegularFile -Path $DestinationInventoryPath -Kind 'Destination inventory'
    $compiler = Assert-CcodSetupRegularFile -Path $CompilerPath -Kind 'Inno compiler'
    try { $payloadRecord = [IO.File]::ReadAllText($payload,[Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Installer payload manifest is invalid JSON' $payload }
    if ($payloadRecord.schemaVersion -isnot [int] -or $payloadRecord.schemaVersion -ne 1 -or
        $payloadRecord.projectVersion -isnot [string] -or $payloadRecord.projectVersion -cne $Version -or
        @($payloadRecord.files).Count -eq 0) { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Installer payload manifest metadata is invalid' $payload }
    $payloadHash = Get-CcodSetupArtifactHash -Path $payload
    $compilerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($compiler)
    $record = [ordered]@{
        schemaVersion = 1
        product = 'CodexRemote-fix'
        version = $Version
        gitCommit = $GitCommit
        buildTimestampUtc = $BuildTimestampUtc
        payloadManifest = [ordered]@{
            name = 'installer-payload.manifest.json'
            length = [int64](Get-Item -LiteralPath $payload -Force).Length
            sha256 = $payloadHash
            fileCount = [int]@($payloadRecord.files).Count
        }
        buildInputs = [ordered]@{
            innoTemplateSha256 = Get-CcodSetupArtifactHash -Path $template
            destinationInventorySha256 = Get-CcodSetupArtifactHash -Path $inventory
            compilerSha256 = Get-CcodSetupArtifactHash -Path $compiler
            compilerFileVersion = [string]$compilerVersion.FileVersion
        }
        peContract = [ordered]@{
            fileVersion = "$Version.0"
            productVersion = "$Version.0"
            productName = 'CodexRemote-fix'
            fileDescription = Get-CcodSetupDescription -Version $Version
            companyName = $GitCommit
            legalCopyright = $payloadHash
        }
    }
    $output = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Refusing to overwrite Setup provenance' $output }
    [IO.File]::WriteAllText($output,(($record | ConvertTo-Json -Depth 8) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]$record
}

function Test-CcodSetupBuildProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProvenancePath,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPayloadManifestSha256,
        [string]$ExpectedBuildTimestampUtc
    )
    $path = Assert-CcodSetupRegularFile -Path $ProvenancePath -Kind 'Setup provenance'
    try { $raw = [IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false)); $record = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Setup provenance is invalid JSON' $path }
    $timestampMatches = [regex]::Matches($raw,'"buildTimestampUtc"\s*:\s*"(?<value>[^"\\]+)"')
    $timestampText = if ($timestampMatches.Count -eq 1) { [string]$timestampMatches[0].Groups['value'].Value } else { $null }
    $fields = @('schemaVersion','product','version','gitCommit','buildTimestampUtc','payloadManifest','buildInputs','peContract')
    if ($record -isnot [pscustomobject] -or ((@($record.PSObject.Properties.Name | Sort-Object) -join '|') -cne (@($fields | Sort-Object) -join '|')) -or
        ($record.schemaVersion -isnot [int] -and $record.schemaVersion -isnot [long]) -or [int64]$record.schemaVersion -ne 1 -or $record.product -isnot [string] -or $record.product -cne 'CodexRemote-fix' -or
        $record.version -isnot [string] -or $record.version -cne $ExpectedVersion -or $record.gitCommit -isnot [string] -or $record.gitCommit -cne $ExpectedGitCommit -or
        -not (Test-CcodSetupCanonicalUtc $timestampText) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedBuildTimestampUtc) -and $timestampText -cne $ExpectedBuildTimestampUtc) -or
        $record.payloadManifest.sha256 -isnot [string] -or $record.payloadManifest.sha256 -cne $ExpectedPayloadManifestSha256 -or
        $record.payloadManifest.name -isnot [string] -or $record.payloadManifest.name -cne 'installer-payload.manifest.json' -or
        [int64]$record.payloadManifest.length -le 0 -or [int]$record.payloadManifest.fileCount -le 0 -or
        $record.peContract.fileVersion -isnot [string] -or $record.peContract.fileVersion -cne "$ExpectedVersion.0" -or
        $record.peContract.productVersion -isnot [string] -or $record.peContract.productVersion -cne "$ExpectedVersion.0" -or
        $record.peContract.productName -isnot [string] -or $record.peContract.productName -cne 'CodexRemote-fix' -or
        $record.peContract.fileDescription -isnot [string] -or $record.peContract.fileDescription -cne (Get-CcodSetupDescription -Version $ExpectedVersion) -or
        $record.peContract.companyName -isnot [string] -or $record.peContract.companyName -cne $ExpectedGitCommit -or
        $record.peContract.legalCopyright -isnot [string] -or $record.peContract.legalCopyright -cne $ExpectedPayloadManifestSha256 -or
        $record.buildInputs.innoTemplateSha256 -isnot [string] -or $record.buildInputs.innoTemplateSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $record.buildInputs.destinationInventorySha256 -isnot [string] -or $record.buildInputs.destinationInventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $record.buildInputs.compilerSha256 -isnot [string] -or $record.buildInputs.compilerSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $record.buildInputs.compilerFileVersion -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$record.buildInputs.compilerFileVersion)) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Setup provenance is not exactly bound to the release contract' $path
    }
    return $record
}

Export-ModuleMember -Function Get-CcodSetupArtifactHash,Get-CcodSetupDescription,New-CcodSetupBuildProvenance,Test-CcodSetupBuildProvenance,Test-CcodSetupArtifact
