[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ChangelogPath,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Tag -cnotmatch '^v\d+\.\d+\.\d+$') {
    throw 'CCOD_RELEASE_NOTES_TAG_INVALID'
}

$changelog = [IO.Path]::GetFullPath($ChangelogPath)
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $changelog -PathType Leaf)) {
    throw 'CCOD_RELEASE_NOTES_CHANGELOG_MISSING'
}
$outputParent = [IO.Path]::GetDirectoryName($output)
if ([string]::IsNullOrWhiteSpace($outputParent) -or -not [IO.Directory]::Exists($outputParent)) {
    throw 'CCOD_RELEASE_NOTES_OUTPUT_INVALID'
}

$text = [IO.File]::ReadAllText($changelog,[Text.UTF8Encoding]::new($false))
$releasePattern = '(?ms)^## ' + [regex]::Escape($Tag) + '[ \t]*\r?\n(?<body>.*?)(?=^## |\z)'
$releaseSections = @([regex]::Matches($text,$releasePattern))
if ($releaseSections.Count -ne 1) {
    throw 'CCOD_RELEASE_NOTES_RELEASE_SECTION_INVALID'
}
$englishSections = @([regex]::Matches($releaseSections[0].Groups['body'].Value,'(?ms)^### English[ \t]*\r?\n(?<body>.*?)(?=^### |\z)'))
if ($englishSections.Count -ne 1) {
    throw 'CCOD_RELEASE_NOTES_ENGLISH_SECTION_INVALID'
}
$english = $englishSections[0].Groups['body'].Value.Trim().Replace("`r`n","`n").Replace("`r","`n")
if ([string]::IsNullOrWhiteSpace($english)) {
    throw 'CCOD_RELEASE_NOTES_ENGLISH_SECTION_INVALID'
}

$version = $Tag.Substring(1)
$notes = "# CodexRemote-fix $version`n`n$english`n"
[IO.File]::WriteAllText($output,$notes,[Text.UTF8Encoding]::new($false))

[pscustomobject][ordered]@{
    Tag = $Tag
    Version = $version
    OutputPath = $output
}
