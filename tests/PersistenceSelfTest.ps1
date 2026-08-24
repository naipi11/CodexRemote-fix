$ErrorActionPreference = 'Stop'

# npm can invoke this Windows PowerShell harness from a PowerShell 7 parent.
# Restore the Desktop module discovery paths before starting child self-tests so
# inbox cmdlets such as Get-FileHash remain available.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $desktopModulePaths = @(
        [Environment]::GetEnvironmentVariable('PSModulePath', 'User'),
        [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($desktopModulePaths.Count -gt 0) {
        $env:PSModulePath = $desktopModulePaths -join ';'
    }
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'persistence') -Filter '*.SelfTest.ps1' | Sort-Object Name
foreach ($test in $tests) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Persistence self-test failed: $($test.Name)" }
}
