$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$galleryPath = Join-Path $repositoryRoot 'tests\manual\Show-TrayUiGallery.ps1'
$results = [Collections.Generic.List[object]]::new()

$results.Add((Invoke-CcodTest 'gallery script exists and parses as PowerShell' {
    if (-not [IO.File]::Exists($galleryPath)) {
        throw 'MISSING_TRAY_UI_GALLERY: tests\manual\Show-TrayUiGallery.ps1'
    }
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($galleryPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-CcodEqual 0 @($parseErrors).Count 'gallery script has no parse errors'
}))

$results.Add((Invoke-CcodTest 'gallery exposes strict locale and state choices' {
    $source = [IO.File]::ReadAllText($galleryPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source -match "\[ValidateSet\('All','zh-CN','en-US'\)\]\s*\[string\]\s*\`$Locale") 'locale uses the exact gallery choices'
    Assert-CcodTrue ($source -match "\[ValidateSet\('All','WaitingForCodex','Checking','Connected','RepairNeeded','Error'\)\]\s*\[string\]\s*\`$State") 'state uses the exact v2 gallery choices'
    Assert-CcodTrue ($source -match '\[ValidateRange\(1,600\)\]\s*\[int\]\s*\$DurationSeconds') 'duration has a bounded range'
    Assert-CcodTrue ($source -match '\[switch\]\s*\$OpenMenu') 'optional screenshot menu switch is explicit'
}))

$results.Add((Invoke-CcodTest 'gallery owns tray lifetime and declares its visual-only boundary' {
    $source = [IO.File]::ReadAllText($galleryPath, [Text.UTF8Encoding]::new($false))
    foreach ($required in @(
        'Get-CcodUiCatalog',
        'New-CcodTrayContext',
        'Set-CcodTrayPresentation',
        'Close-CcodTrayContext',
        'Visual-only legacy diagnostic',
        'ConnectionState',
        'ProtectionState'
    )) {
        Assert-CcodTrue ($source.Contains($required)) "gallery contains $required"
    }
    foreach ($forbidden in @(
        '(?m)^\s*Start-Process\b',
        '(?m)^\s*Stop-Process\b',
        '(?m)^\s*Write-CcodAtomicJson\b',
        '(?m)^\s*Set-CcodUiLanguageMode\b',
        '(?m)^\s*Set-CcodAutomationEnabled\b',
        '(?m)^\s*Set-CcodCandidateCompatibleOptIn\b'
    )) {
        Assert-CcodTrue (-not [Text.RegularExpressions.Regex]::IsMatch($source, $forbidden)) "gallery does not contain $forbidden"
    }
    Assert-CcodTrue ($source -match '(?s)try\s*\{.*finally\s*\{') 'gallery closes resources in finally'
}))

$results | ForEach-Object { "PASS $($_.Name)" }
Write-Output "TrayUiGallery self-tests passed: $($results.Count)"
