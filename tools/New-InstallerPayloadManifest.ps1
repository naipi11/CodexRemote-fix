[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$ProjectVersion,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CcodInstallerPayloadSha256 {
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

function Test-CcodInstallerPayloadRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -and -not $Path.Contains('//') -and -not $Path.Contains('..') -and -not $Path.Contains(':')
}

if ($ProjectVersion -cnotmatch '^\d+\.\d+\.\d+$') { throw "Invalid installer payload project version: $ProjectVersion" }
$root = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not [IO.Directory]::Exists($root)) { throw "Installer payload root is missing: $root" }
if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) { throw "Refusing to overwrite installer payload manifest: $output" }
$rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installer payload root is a reparse point: $root" }
$prefix = $root + '\'
$records = [Collections.Generic.List[object]]::new()
foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installer payload contains a reparse point: $($item.FullName)" }
    if ($item.PSIsContainer) { continue }
    $full = [IO.Path]::GetFullPath($item.FullName)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Installer payload file escaped its root: $full" }
    $relative = $full.Substring($prefix.Length).Replace('\','/')
    if (-not (Test-CcodInstallerPayloadRelativePath $relative)) { throw "Installer payload relative path is invalid: $relative" }
    $records.Add([pscustomobject][ordered]@{path=$relative;length=[int64]$item.Length;sha256=Get-CcodInstallerPayloadSha256 -Path $full})
}
$comparison = [System.Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)}
$records.Sort($comparison)
if ($records.Count -eq 0) { throw 'Installer payload is empty.' }
$manifest = [ordered]@{schemaVersion=1;projectVersion=$ProjectVersion;files=@($records)}
$outputParent = Split-Path $output -Parent
if (-not [IO.Directory]::Exists($outputParent)) { [IO.Directory]::CreateDirectory($outputParent) | Out-Null }
[IO.File]::WriteAllText($output,(($manifest|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
Write-Output ([pscustomobject]$manifest)
