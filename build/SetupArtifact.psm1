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

function Initialize-CcodSetupJsonMemberScanner {
    if ($null -ne ('CcodSetupJsonMemberScannerV1' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

public static class CcodSetupJsonMemberScannerV1
{
    public static void AssertUnique(string json)
    {
        if (json == null || json.Length == 0 || json.Length > 1048576) throw new InvalidDataException("json bounds");
        int index = 0;
        ParseValue(json, ref index, 0);
        Skip(json, ref index);
        if (index != json.Length) throw new InvalidDataException("trailing json");
    }

    private static void ParseValue(string json, ref int index, int depth)
    {
        if (depth > 32) throw new InvalidDataException("json depth");
        Skip(json, ref index);
        if (index >= json.Length) throw new InvalidDataException("missing value");
        char c = json[index];
        if (c == '{') { ParseObject(json, ref index, depth + 1); return; }
        if (c == '[') { ParseArray(json, ref index, depth + 1); return; }
        if (c == '"') { ParseString(json, ref index); return; }
        int start = index;
        while (index < json.Length && json[index] != ',' && json[index] != '}' && json[index] != ']' && !Char.IsWhiteSpace(json[index])) index++;
        if (index == start) throw new InvalidDataException("invalid scalar");
    }

    private static void ParseObject(string json, ref int index, int depth)
    {
        index++;
        var names = new HashSet<string>(StringComparer.Ordinal);
        Skip(json, ref index);
        if (index < json.Length && json[index] == '}') { index++; return; }
        while (true)
        {
            Skip(json, ref index);
            if (index >= json.Length || json[index] != '"') throw new InvalidDataException("object key");
            string name = ParseString(json, ref index);
            if (!names.Add(name)) throw new InvalidDataException("duplicate object member: " + name);
            Skip(json, ref index);
            if (index >= json.Length || json[index] != ':') throw new InvalidDataException("object colon");
            index++;
            ParseValue(json, ref index, depth);
            Skip(json, ref index);
            if (index >= json.Length) throw new InvalidDataException("object end");
            if (json[index] == '}') { index++; return; }
            if (json[index] != ',') throw new InvalidDataException("object comma");
            index++;
        }
    }

    private static void ParseArray(string json, ref int index, int depth)
    {
        index++;
        Skip(json, ref index);
        if (index < json.Length && json[index] == ']') { index++; return; }
        while (true)
        {
            ParseValue(json, ref index, depth);
            Skip(json, ref index);
            if (index >= json.Length) throw new InvalidDataException("array end");
            if (json[index] == ']') { index++; return; }
            if (json[index] != ',') throw new InvalidDataException("array comma");
            index++;
        }
    }

    private static string ParseString(string json, ref int index)
    {
        if (json[index] != '"') throw new InvalidDataException("string start");
        index++;
        var value = new StringBuilder();
        while (index < json.Length)
        {
            char c = json[index++];
            if (c == '"') return value.ToString();
            if (c < 0x20) throw new InvalidDataException("string control");
            if (c != '\\') { value.Append(c); continue; }
            if (index >= json.Length) throw new InvalidDataException("string escape");
            char escaped = json[index++];
            switch (escaped)
            {
                case '"': value.Append('"'); break;
                case '\\': value.Append('\\'); break;
                case '/': value.Append('/'); break;
                case 'b': value.Append('\b'); break;
                case 'f': value.Append('\f'); break;
                case 'n': value.Append('\n'); break;
                case 'r': value.Append('\r'); break;
                case 't': value.Append('\t'); break;
                case 'u':
                    if (index + 4 > json.Length) throw new InvalidDataException("unicode escape");
                    int code;
                    if (!Int32.TryParse(json.Substring(index, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code)) throw new InvalidDataException("unicode escape");
                    value.Append((char)code); index += 4; break;
                default: throw new InvalidDataException("unknown escape");
            }
        }
        throw new InvalidDataException("unterminated string");
    }

    private static void Skip(string json, ref int index)
    {
        while (index < json.Length && Char.IsWhiteSpace(json[index])) index++;
    }
}
'@
}

function Assert-CcodSetupUniqueJsonMembers {
    param([Parameter(Mandatory)][string]$Json,[Parameter(Mandatory)]$Target)
    try {
        Initialize-CcodSetupJsonMemberScanner
        [CcodSetupJsonMemberScannerV1]::AssertUnique($Json)
    } catch {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'JSON contains duplicate members or is outside the bounded raw schema' $Target
    }
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
        [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPayloadManifestSha256,
        [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPackageSha256,
        [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPackageManifestSha256,
        [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedActivationBootstrapSha256
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
    $originalFilename = ([string]$versionInfo.OriginalFilename).Trim()
    $sealedContract = -not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedPackageManifestSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedActivationBootstrapSha256)
    if ($sealedContract -and ([string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or [string]::IsNullOrWhiteSpace($ExpectedPackageManifestSha256) -or [string]::IsNullOrWhiteSpace($ExpectedActivationBootstrapSha256))) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PAYLOAD_BINDING_INVALID' 'The sealed Setup PE contract requires all three hashes' $setup
    }
    $expectedProductVersion = if ($sealedContract) { $ExpectedPackageManifestSha256.Substring(0,32) } else { $expectedPeVersion }
    if ($sealedContract) { $expectedDescription = $ExpectedPackageManifestSha256.Substring(32,32) }
    $expectedProductName = if ($sealedContract) { $ExpectedActivationBootstrapSha256.Substring(32,32) } else { 'CodexRemote-fix' }
    $expectedOriginalFilename = if ($sealedContract) { $ExpectedActivationBootstrapSha256.Substring(0,32) } else { $originalFilename }
    if ($fileVersion -cne $expectedPeVersion -or $productVersion -cne $expectedProductVersion) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PE_VERSION_INVALID' ("Setup PE FileVersion/ProductVersion do not match the release version: file={0}; product={1}; expected={2}" -f [string]$versionInfo.FileVersion,[string]$versionInfo.ProductVersion,$expectedPeVersion) $setup
    }
    $expectedCopyright = if ($sealedContract) { $ExpectedPackageSha256 } else { $ExpectedPayloadManifestSha256 }
    if ($productName -cne $expectedProductName -or $fileDescription -cne $expectedDescription -or
        $companyName -cne $ExpectedGitCommit -or $legalCopyright -cne $expectedCopyright -or
        ($sealedContract -and $originalFilename -cne $expectedOriginalFilename)) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PAYLOAD_BINDING_INVALID' ("Setup PE does not bind the expected version, commit, package, manifest, and bootstrap hashes: product={0}; productVersion={1}; description={2}; company={3}; copyright={4}; original={5}" -f $productName,$productVersion,$fileDescription,$companyName,$legalCopyright,$originalFilename) $setup
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
        OriginalFilename = $originalFilename
        PackageManifestSha256 = if ($sealedContract) { $productVersion + $fileDescription } else { $null }
        ActivationBootstrapSha256 = if ($sealedContract) { $originalFilename + $productName } else { $null }
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
        [string]$ExpectedBuildTimestampUtc,
        [Parameter(Mandatory)][string]$InnoTemplatePath,
        [Parameter(Mandatory)][string]$DestinationInventoryPath,
        [Parameter(Mandatory)][string]$CompilerPath,
        [Parameter(Mandatory)][string]$PayloadManifestPath
    )
    $path = Assert-CcodSetupRegularFile -Path $ProvenancePath -Kind 'Setup provenance'
    $template = Assert-CcodSetupRegularFile -Path $InnoTemplatePath -Kind 'Inno template'
    $inventory = Assert-CcodSetupRegularFile -Path $DestinationInventoryPath -Kind 'Destination inventory'
    $compiler = Assert-CcodSetupRegularFile -Path $CompilerPath -Kind 'Inno compiler'
    $payload = Assert-CcodSetupRegularFile -Path $PayloadManifestPath -Kind 'Installer payload manifest'
    try { $payloadRaw = [IO.File]::ReadAllText($payload,[Text.UTF8Encoding]::new($false)); $payloadRecord = $payloadRaw | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Canonical installer payload manifest is invalid' $payload }
    $actualPayloadHash = Get-CcodSetupArtifactHash -Path $payload
    $actualCompilerVersion = ([string][Diagnostics.FileVersionInfo]::GetVersionInfo($compiler).FileVersion).Trim()
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
        $record.payloadManifest.sha256 -isnot [string] -or $record.payloadManifest.sha256 -cne $ExpectedPayloadManifestSha256 -or $record.payloadManifest.sha256 -cne $actualPayloadHash -or
        $record.payloadManifest.name -isnot [string] -or $record.payloadManifest.name -cne 'installer-payload.manifest.json' -or
        [int64]$record.payloadManifest.length -ne [int64](Get-Item -LiteralPath $payload -Force).Length -or
        [int]$record.payloadManifest.fileCount -ne [int]@($payloadRecord.files).Count -or
        $record.peContract.fileVersion -isnot [string] -or $record.peContract.fileVersion -cne "$ExpectedVersion.0" -or
        $record.peContract.productVersion -isnot [string] -or $record.peContract.productVersion -cne "$ExpectedVersion.0" -or
        $record.peContract.productName -isnot [string] -or $record.peContract.productName -cne 'CodexRemote-fix' -or
        $record.peContract.fileDescription -isnot [string] -or $record.peContract.fileDescription -cne (Get-CcodSetupDescription -Version $ExpectedVersion) -or
        $record.peContract.companyName -isnot [string] -or $record.peContract.companyName -cne $ExpectedGitCommit -or
        $record.peContract.legalCopyright -isnot [string] -or $record.peContract.legalCopyright -cne $ExpectedPayloadManifestSha256 -or
        $record.buildInputs.innoTemplateSha256 -isnot [string] -or $record.buildInputs.innoTemplateSha256 -cne (Get-CcodSetupArtifactHash -Path $template) -or
        $record.buildInputs.destinationInventorySha256 -isnot [string] -or $record.buildInputs.destinationInventorySha256 -cne (Get-CcodSetupArtifactHash -Path $inventory) -or
        $record.buildInputs.compilerSha256 -isnot [string] -or $record.buildInputs.compilerSha256 -cne (Get-CcodSetupArtifactHash -Path $compiler) -or
        $record.buildInputs.compilerFileVersion -isnot [string] -or ([string]$record.buildInputs.compilerFileVersion).Trim() -cne $actualCompilerVersion) {
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Setup provenance is not exactly bound to the release contract' $path
    }
    return $record
}

function New-CcodSealedSetupBuildProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$GitCommit,
        [Parameter(Mandatory)][string]$BuildTimestampUtc,
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$PackageManifestPath,
        [Parameter(Mandatory)][string]$ActivationBootstrapPath,
        [Parameter(Mandatory)][string]$InnoTemplatePath,
        [Parameter(Mandatory)][string]$DestinationInventoryPath,
        [Parameter(Mandatory)][string]$CompilerPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if (-not (Test-CcodSetupCanonicalUtc $BuildTimestampUtc)) { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Sealed Setup provenance timestamp is invalid' $BuildTimestampUtc }
    $package=Assert-CcodSetupRegularFile $PackagePath 'Installer package';$manifest=Assert-CcodSetupRegularFile $PackageManifestPath 'Installer package manifest';$bootstrap=Assert-CcodSetupRegularFile $ActivationBootstrapPath 'Activation bootstrap';$template=Assert-CcodSetupRegularFile $InnoTemplatePath 'Inno template';$inventory=Assert-CcodSetupRegularFile $DestinationInventoryPath 'Destination inventory';$compiler=Assert-CcodSetupRegularFile $CompilerPath 'Inno compiler'
    try{$manifestRecord=[IO.File]::ReadAllText($manifest,[Text.UTF8Encoding]::new($false))|ConvertFrom-Json -ErrorAction Stop}catch{Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Installer package manifest JSON is invalid' $manifest}
    if($manifestRecord.schemaVersion-isnot[int]-or$manifestRecord.schemaVersion-ne 1-or$manifestRecord.product-cne'CodexRemote-fix'-or$manifestRecord.version-cne$Version-or$manifestRecord.gitCommit-cne$GitCommit-or@($manifestRecord.files).Count-eq0){Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Installer package manifest identity is invalid' $manifest}
    $packageHash=Get-CcodSetupArtifactHash $package;$manifestHash=Get-CcodSetupArtifactHash $manifest;$bootstrapHash=Get-CcodSetupArtifactHash $bootstrap;$compilerInfo=[Diagnostics.FileVersionInfo]::GetVersionInfo($compiler)
    $record=[ordered]@{
        schemaVersion=2;product='CodexRemote-fix';version=$Version;gitCommit=$GitCommit;buildTimestampUtc=$BuildTimestampUtc
        installerPackage=[ordered]@{name='installer-package.zip';length=[int64](Get-Item $package -Force).Length;sha256=$packageHash}
        installerPackageManifest=[ordered]@{name='installer-package.manifest.json';length=[int64](Get-Item $manifest -Force).Length;sha256=$manifestHash;fileCount=[int]@($manifestRecord.files).Count;payloadManifestSha256=[string]$manifestRecord.payloadManifest.sha256}
        activationBootstrap=[ordered]@{name='Activate-CcodRemoteFix.ps1';length=[int64](Get-Item $bootstrap -Force).Length;sha256=$bootstrapHash}
        buildInputs=[ordered]@{innoTemplateSha256=Get-CcodSetupArtifactHash $template;destinationInventorySha256=Get-CcodSetupArtifactHash $inventory;compilerSha256=Get-CcodSetupArtifactHash $compiler;compilerFileVersion=[string]$compilerInfo.FileVersion}
        peContract=[ordered]@{fileVersion="$Version.0";packageManifestFirst=$manifestHash.Substring(0,32);packageManifestLast=$manifestHash.Substring(32,32);bootstrapFirst=$bootstrapHash.Substring(0,32);bootstrapLast=$bootstrapHash.Substring(32,32);companyName=$GitCommit;legalCopyright=$packageHash}
    }
    $output=[IO.Path]::GetFullPath($OutputPath);if([IO.File]::Exists($output)-or[IO.Directory]::Exists($output)){Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Refusing to overwrite sealed Setup provenance' $output}
    [IO.File]::WriteAllText($output,(($record|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false));return [pscustomobject]$record
}

function Test-CcodSealedSetupBuildProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProvenancePath,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPackageSha256,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPackageManifestSha256,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedActivationBootstrapSha256,[Parameter(Mandatory)][string]$ExpectedBuildTimestampUtc,
        [Parameter(Mandatory)][string]$PackagePath,[Parameter(Mandatory)][string]$PackageManifestPath,[Parameter(Mandatory)][string]$ActivationBootstrapPath,[Parameter(Mandatory)][string]$InnoTemplatePath,[Parameter(Mandatory)][string]$DestinationInventoryPath,[Parameter(Mandatory)][string]$CompilerPath
    )
    $path=Assert-CcodSetupRegularFile $ProvenancePath 'Sealed Setup provenance'
    $package=Assert-CcodSetupRegularFile $PackagePath 'Installer package'
    $manifest=Assert-CcodSetupRegularFile $PackageManifestPath 'Installer package manifest'
    $bootstrap=Assert-CcodSetupRegularFile $ActivationBootstrapPath 'Activation bootstrap'
    $template=Assert-CcodSetupRegularFile $InnoTemplatePath 'Inno template'
    $inventory=Assert-CcodSetupRegularFile $DestinationInventoryPath 'Destination inventory'
    $compiler=Assert-CcodSetupRegularFile $CompilerPath 'Inno compiler'
    try {
        $raw=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false))
        Assert-CcodSetupUniqueJsonMembers -Json $raw -Target $path
        $record=$raw|ConvertFrom-Json -ErrorAction Stop
        $manifestRaw=[IO.File]::ReadAllText($manifest,[Text.UTF8Encoding]::new($false))
        Assert-CcodSetupUniqueJsonMembers -Json $manifestRaw -Target $manifest
        $packageManifest=$manifestRaw|ConvertFrom-Json -ErrorAction Stop
    } catch { Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Sealed Setup provenance or package manifest JSON is invalid' $path }

    function Test-CcodExactObjectProperties {
        param($Value,[string[]]$Names)
        return $Value-is[pscustomobject]-and(@($Value.PSObject.Properties.Name)-join',')-ceq($Names-join',')
    }
    function Test-CcodJsonInteger {
        param($Value)
        return ($Value-is[int]-or$Value-is[long])-and[decimal]$Value-eq[decimal][long]$Value
    }
    function Test-CcodExactString {
        param($Value,[string]$Expected)
        return $Value-is[string]-and$Value-ceq$Expected
    }

    $top=@('schemaVersion','product','version','gitCommit','buildTimestampUtc','installerPackage','installerPackageManifest','activationBootstrap','buildInputs','peContract')
    $artifactFields=@('name','length','sha256')
    $manifestFields=@('name','length','sha256','fileCount','payloadManifestSha256')
    $buildFields=@('innoTemplateSha256','destinationInventorySha256','compilerSha256','compilerFileVersion')
    $peFields=@('fileVersion','packageManifestFirst','packageManifestLast','bootstrapFirst','bootstrapLast','companyName','legalCopyright')
    $packageManifestFields=@('schemaVersion','product','version','gitCommit','payloadManifest','files')
    $payloadManifestFields=@('name','length','sha256')
    if(-not(Test-CcodExactObjectProperties $record $top)-or
       -not(Test-CcodExactObjectProperties $record.installerPackage $artifactFields)-or
       -not(Test-CcodExactObjectProperties $record.installerPackageManifest $manifestFields)-or
       -not(Test-CcodExactObjectProperties $record.activationBootstrap $artifactFields)-or
       -not(Test-CcodExactObjectProperties $record.buildInputs $buildFields)-or
       -not(Test-CcodExactObjectProperties $record.peContract $peFields)-or
       -not(Test-CcodExactObjectProperties $packageManifest $packageManifestFields)-or
       -not(Test-CcodExactObjectProperties $packageManifest.payloadManifest $payloadManifestFields)){
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Sealed Setup provenance property schema is invalid' $path
    }
    $actualCompilerVersion=([string][Diagnostics.FileVersionInfo]::GetVersionInfo($compiler).FileVersion).Trim()
    $packageLength=[long](Get-Item $package -Force).Length
    $manifestLength=[long](Get-Item $manifest -Force).Length
    $bootstrapLength=[long](Get-Item $bootstrap -Force).Length
    if($record.schemaVersion-isnot[int]-or$record.schemaVersion-ne 2-or
       -not(Test-CcodExactString $record.product 'CodexRemote-fix')-or
       -not(Test-CcodExactString $record.version $ExpectedVersion)-or
       -not(Test-CcodExactString $record.gitCommit $ExpectedGitCommit)-or
       -not(Test-CcodExactString $record.buildTimestampUtc $ExpectedBuildTimestampUtc)-or
       -not(Test-CcodSetupCanonicalUtc $record.buildTimestampUtc)-or
       $packageManifest.schemaVersion-isnot[int]-or$packageManifest.schemaVersion-ne 1-or
       -not(Test-CcodExactString $packageManifest.product 'CodexRemote-fix')-or
       -not(Test-CcodExactString $packageManifest.version $ExpectedVersion)-or
       -not(Test-CcodExactString $packageManifest.gitCommit $ExpectedGitCommit)-or
       -not(Test-CcodExactString $packageManifest.payloadManifest.name 'installer-payload.manifest.json')-or
       -not(Test-CcodJsonInteger $packageManifest.payloadManifest.length)-or[long]$packageManifest.payloadManifest.length-le0-or
       @($packageManifest.files).Count-le0-or
       -not(Test-CcodExactString $record.installerPackage.name 'installer-package.zip')-or
       -not(Test-CcodJsonInteger $record.installerPackage.length)-or[long]$record.installerPackage.length-ne$packageLength-or
       -not(Test-CcodExactString $record.installerPackage.sha256 $ExpectedPackageSha256)-or$record.installerPackage.sha256-cne(Get-CcodSetupArtifactHash $package)-or
       -not(Test-CcodExactString $record.installerPackageManifest.name 'installer-package.manifest.json')-or
       -not(Test-CcodJsonInteger $record.installerPackageManifest.length)-or[long]$record.installerPackageManifest.length-ne$manifestLength-or
       -not(Test-CcodExactString $record.installerPackageManifest.sha256 $ExpectedPackageManifestSha256)-or$record.installerPackageManifest.sha256-cne(Get-CcodSetupArtifactHash $manifest)-or
       $record.installerPackageManifest.fileCount-isnot[int]-or$record.installerPackageManifest.fileCount-ne@($packageManifest.files).Count-or
       -not(Test-CcodExactString $record.installerPackageManifest.payloadManifestSha256 ([string]$packageManifest.payloadManifest.sha256))-or
       $packageManifest.payloadManifest.sha256-isnot[string]-or$packageManifest.payloadManifest.sha256-cnotmatch'^[0-9a-f]{64}$'-or
       -not(Test-CcodExactString $record.activationBootstrap.name 'Activate-CcodRemoteFix.ps1')-or
       -not(Test-CcodJsonInteger $record.activationBootstrap.length)-or[long]$record.activationBootstrap.length-ne$bootstrapLength-or
       -not(Test-CcodExactString $record.activationBootstrap.sha256 $ExpectedActivationBootstrapSha256)-or$record.activationBootstrap.sha256-cne(Get-CcodSetupArtifactHash $bootstrap)-or
       -not(Test-CcodExactString $record.buildInputs.innoTemplateSha256 (Get-CcodSetupArtifactHash $template))-or
       -not(Test-CcodExactString $record.buildInputs.destinationInventorySha256 (Get-CcodSetupArtifactHash $inventory))-or
       -not(Test-CcodExactString $record.buildInputs.compilerSha256 (Get-CcodSetupArtifactHash $compiler))-or
       -not(Test-CcodExactString $record.buildInputs.compilerFileVersion $actualCompilerVersion)-or
       -not(Test-CcodExactString $record.peContract.fileVersion "$ExpectedVersion.0")-or
       -not(Test-CcodExactString $record.peContract.packageManifestFirst $ExpectedPackageManifestSha256.Substring(0,32))-or
       -not(Test-CcodExactString $record.peContract.packageManifestLast $ExpectedPackageManifestSha256.Substring(32,32))-or
       -not(Test-CcodExactString $record.peContract.bootstrapFirst $ExpectedActivationBootstrapSha256.Substring(0,32))-or
       -not(Test-CcodExactString $record.peContract.bootstrapLast $ExpectedActivationBootstrapSha256.Substring(32,32))-or
       -not(Test-CcodExactString $record.peContract.companyName $ExpectedGitCommit)-or
       -not(Test-CcodExactString $record.peContract.legalCopyright $ExpectedPackageSha256)){
        Throw-CcodSetupArtifactError 'CCOD_SETUP_PROVENANCE_INVALID' 'Sealed Setup provenance is not exactly bound' $path
    }
    return $record
}

Export-ModuleMember -Function Get-CcodSetupArtifactHash,Get-CcodSetupDescription,New-CcodSetupBuildProvenance,Test-CcodSetupBuildProvenance,New-CcodSealedSetupBuildProvenance,Test-CcodSealedSetupBuildProvenance,Test-CcodSetupArtifact
