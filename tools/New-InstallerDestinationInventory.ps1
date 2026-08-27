[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$ProjectVersion,
    [Parameter(Mandatory)][string]$InnoScriptPath,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ProjectVersion -cnotmatch '^\d+\.\d+\.\d+$') { throw "Invalid project version: $ProjectVersion" }
$repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$payload = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
$inno = [IO.Path]::GetFullPath($InnoScriptPath)
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not [IO.Directory]::Exists($repository) -or -not [IO.Directory]::Exists($payload) -or -not [IO.File]::Exists($inno)) { throw 'Setup destination inventory input is missing.' }
if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) { throw "Refusing to overwrite setup destination inventory: $output" }

$directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
function Add-CcodExpectedDirectory {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Relative)
    $normalized = $Relative.Replace('/','\').Trim('\')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return }
    if ($normalized -notmatch '^[A-Za-z0-9._-]+(?:\\[A-Za-z0-9._-]+)*$') { throw "Unsafe setup destination directory: $normalized" }
    $segments = $normalized -split '\\'
    $current = ''
    foreach ($segment in $segments) {
        $current = if ([string]::IsNullOrEmpty($current)) { $segment } else { "$current\$segment" }
        [void]$directories.Add($current)
    }
}

function Assert-CcodInstallerInnoPreprocessorLines {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $allowedSimpleDirectives = @(
        '#ifndef TrayHostArtifactDirectory',
        '#define TrayHostArtifactDirectory SourcePath + "\generated\trayhost"',
        '#ifndef PortableArtifactDirectory',
        '#define PortableArtifactDirectory SourcePath + "\generated\portable"',
        '#ifndef InstallerPayloadDirectory',
        '#error InstallerPayloadDirectory must be supplied by the release builder',
        '#ifndef InstallerPayloadManifestSha256',
        '#error InstallerPayloadManifestSha256 must be supplied by the release builder',
        '#endif'
    )
    $allowedInlineConstructs = @(
        '{#ProjectVersion}',
        '{#TrayHostArtifactDirectory}',
        '{#PortableArtifactDirectory}',
        '{#InstallerPayloadDirectory}',
        '{#InstallerPayloadManifestSha256}'
    )
    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = [string]$Lines[$lineIndex]
        $lineNumber = $lineIndex + 1
        if ($line -match '\\\s*$') {
            throw "Setup destination inventory requires an include-free simple preprocessor template; line continuation is not permitted at line $lineNumber."
        }
        if ($line -match '^\s*#' -and $allowedSimpleDirectives -cnotcontains $line) {
            throw "Setup destination inventory requires an include-free exact preprocessor template; unsafe simple directive at line ${lineNumber}: $line"
        }
        $inlineStart = $line.IndexOf('{#',[StringComparison]::Ordinal)
        while ($inlineStart -ge 0) {
            $inlineEnd = $line.IndexOf('}',$inlineStart + 2)
            if ($inlineEnd -lt 0) {
                throw "Setup destination inventory contains an unterminated inline preprocessor construct at line $lineNumber."
            }
            $inlineConstruct = $line.Substring($inlineStart,$inlineEnd - $inlineStart + 1)
            if ($allowedInlineConstructs -cnotcontains $inlineConstruct) {
                throw "Setup destination inventory contains an unsafe inline preprocessor construct at line ${lineNumber}: $inlineConstruct"
            }
            $inlineStart = $line.IndexOf('{#',$inlineEnd + 1,[StringComparison]::Ordinal)
        }
    }
}

$lines = @(Get-Content -LiteralPath $inno -Encoding UTF8)
Assert-CcodInstallerInnoPreprocessorLines -Lines $lines
$filesSectionCount = @($lines | Where-Object { $_ -match '^\s*\[Files\]\s*$' }).Count
if ($filesSectionCount -ne 1) { throw "Setup destination inventory requires exactly one [Files] section; found $filesSectionCount." }
$insideFiles = $false
foreach ($line in $lines) {
    if ($line -match '^\s*\[Files\]\s*$') { $insideFiles = $true; continue }
    if ($insideFiles -and $line -match '^\[') { break }
    if (-not $insideFiles -or [string]::IsNullOrWhiteSpace($line)) { continue }
    $match = [regex]::Match($line,'^Source:\s*"(?<source>[^"]+)";\s*DestDir:\s*"(?<destination>[^"]+)";(?<tail>.*)$')
    if (-not $match.Success) { throw "Unsupported [Files] entry for destination inventory: $line" }
    $destination = $match.Groups['destination'].Value.Replace('{#ProjectVersion}',$ProjectVersion)
    if (-not $destination.StartsWith('{app}',[StringComparison]::Ordinal)) { throw "Setup destination is outside app root: $destination" }
    $destinationRelative = $destination.Substring(5).TrimStart('\')
    Add-CcodExpectedDirectory -Relative $destinationRelative
    if ($match.Groups['tail'].Value -cnotmatch '(?:^|\s)recursesubdirs(?:\s|$)') { continue }

    $sourceExpression = $match.Groups['source'].Value
    $sourceRoot = $null
    if ($sourceExpression.StartsWith('{#InstallerPayloadDirectory}',[StringComparison]::Ordinal)) {
        $sourceRoot = $payload
    } elseif ($sourceExpression.StartsWith('..\',[StringComparison]::Ordinal) -and $sourceExpression.EndsWith('\*',[StringComparison]::Ordinal)) {
        $sourceRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path $inno -Parent) $sourceExpression.Substring(0,$sourceExpression.Length-2)))
    } else {
        throw "Recursive [Files] source cannot be inventoried deterministically: $sourceExpression"
    }
    if (-not [IO.Directory]::Exists($sourceRoot)) { throw "Recursive [Files] source root is missing: $sourceRoot" }
    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    foreach ($entry in @(Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse -ErrorAction Stop)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recursive [Files] source contains a reparse point: $($entry.FullName)" }
        $relativeDirectory = if ($entry.PSIsContainer) {
            $entry.FullName.Substring($sourcePrefix.Length)
        } else {
            $parent = Split-Path $entry.FullName -Parent
            if ($parent.Equals($sourceRoot,[StringComparison]::OrdinalIgnoreCase)) { '' } else { $parent.Substring($sourcePrefix.Length) }
        }
        if (-not [string]::IsNullOrWhiteSpace($relativeDirectory)) {
            Add-CcodExpectedDirectory -Relative $(if ([string]::IsNullOrWhiteSpace($destinationRelative)) { $relativeDirectory } else { "$destinationRelative\$relativeDirectory" })
        }
    }
}
if (-not $insideFiles -or $directories.Count -eq 0) { throw 'No setup destination directories were generated.' }
$ordered = [Collections.Generic.List[string]]::new()
foreach ($directory in $directories) { $ordered.Add($directory) }
$ordered.Sort([StringComparer]::Ordinal)
$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('procedure AddCcodExpectedSetupDirectories(Directories: TStrings);')
[void]$builder.AppendLine('begin')
foreach ($directory in $ordered) { [void]$builder.AppendLine("  Directories.Add('$directory');") }
[void]$builder.AppendLine('end;')
[IO.File]::WriteAllText($output,$builder.ToString(),[Text.UTF8Encoding]::new($false))
Write-Output ([pscustomobject]@{Path=$output;Directories=@($ordered)})
