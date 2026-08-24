[CmdletBinding()]
param(
    [switch]$SkipInstalledPackageCheck
)

$ErrorActionPreference = 'Stop'

# npm normally launches this Windows PowerShell entry point from a PowerShell 7
# shell. Preserve the Desktop module discovery paths so child Windows PowerShell
# tests can resolve inbox cmdlets such as Get-FileHash instead of inheriting only
# the PowerShell 7 module layout.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $desktopModulePaths = @(
        [Environment]::GetEnvironmentVariable('PSModulePath', 'User'),
        [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($desktopModulePaths.Count -gt 0) {
        $env:PSModulePath = $desktopModulePaths -join ';'
    }
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()
$cleanRoomSelfTest = Join-Path $PSScriptRoot 'CleanroomSelfTest.js'
$packageCheckerSelfTest = Join-Path $PSScriptRoot 'PackageCheckerSelfTest.mjs'
$persistenceSelfTest = Join-Path $PSScriptRoot 'PersistenceSelfTest.ps1'

foreach ($script in Get-ChildItem -Recurse -File -LiteralPath $projectRoot -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    foreach ($parseError in $parseErrors) {
        $failures.Add("PowerShell parse error in $($script.FullName): $($parseError.Message)")
    }
}

foreach ($module in Get-ChildItem -Recurse -File -LiteralPath $projectRoot -Filter '*.psm1') {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $module.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    foreach ($parseError in $parseErrors) {
        $failures.Add("PowerShell module parse error in $($module.FullName): $($parseError.Message)")
    }
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
    $failures.Add('node.exe is required for JavaScript syntax checks.')
} else {
    foreach ($source in Get-ChildItem -Recurse -File -LiteralPath (Join-Path $projectRoot 'src') | Where-Object {
        $_.Extension -in @('.js', '.mjs')
    }) {
        $syntaxOutput = & $node.Source --check $source.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("Node syntax error in $($source.FullName): $($syntaxOutput -join ' ')")
        }
    }

    if (-not (Test-Path -LiteralPath $cleanRoomSelfTest -PathType Leaf)) {
        $failures.Add("Clean-room runtime self-test is missing: $cleanRoomSelfTest")
    } elseif ($failures.Count -eq 0) {
        $selfTestOutput = & $node.Source $cleanRoomSelfTest 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("Clean-room runtime self-test failed: $($selfTestOutput -join ' ')")
        }
    }

    if ($failures.Count -eq 0) {
        $packageCheckerOutput = & $node.Source $packageCheckerSelfTest 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("Package checker self-test failed: $($packageCheckerOutput -join ' ')")
        }
    }
}

if ($failures.Count -eq 0) {
    $powershellExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # A failing child PowerShell writes a NativeCommandError to stderr. Capture
        # that test evidence and inspect its exit code instead of terminating before
        # the failure report and targeted diagnostic can run.
        $ErrorActionPreference = 'Continue'
        $persistenceOutput = & $powershellExecutable -NoProfile -ExecutionPolicy Bypass -File $persistenceSelfTest 2>&1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        $persistenceText = $persistenceOutput -join ' '
        if ($persistenceText -match 'ASSERT_EQUAL: submission error code expected=\[\] actual=\[CCOD_LIFECYCLE_PATH_INVALID\]') {
            $lifecycleProbe = Join-Path $PSScriptRoot 'persistence\Invoke-LifecycleRequestCiProbe.ps1'
            if (Test-Path -LiteralPath $lifecycleProbe -PathType Leaf) {
                Write-Host 'Lifecycle request CI probe follows:'
                & $powershellExecutable -NoProfile -ExecutionPolicy Bypass -File $lifecycleProbe
            }
        }
        foreach ($line in @($persistenceOutput)) {
            $text = [string]$line
            if ($text -match 'CCOD_LIFECYCLE_TEST_DIAG_') { Write-Host $text }
        }
        $failures.Add("Persistence self-test failed: $($persistenceOutput -join ' ')")
    }
}

foreach ($required in @(
    'README.md',
    'README.zh-CN.md',
    'LICENSE',
    'NOTICE.md',
    'SECURITY.md',
    'package.json',
    'Activate-CcodRemoteFix.ps1',
    'docs\CLEANROOM.md',
    'docs\TECHNICAL.md',
    'Install-CodexControlOtherDevices.ps1',
    'Uninstall-CodexControlOtherDevices.ps1',
    'src\persistence\bootstrap.ps1',
    'src\persistence\UninstallBootstrap.ps1',
    'src\persistence\modules\InstallLifecycle.psm1',
    'src\persistence\modules\ScheduledTask.psm1',
    'src\persistence\modules\WorkerRuntime.psm1',
    'tests\PersistenceSelfTest.ps1',
    'tests\installed\Invoke-InstalledLifecycleIntegration.ps1',
    'tests\persistence\Bootstrap.SelfTest.ps1',
    'tests\persistence\ScheduledTask.SelfTest.ps1',
    'tests\persistence\InstallLifecycle.SelfTest.ps1',
    'tests\persistence\UninstallBootstrap.SelfTest.ps1',
    'tests\persistence\InstalledLifecycleHarness.SelfTest.ps1',
    'tests\persistence\ReleaseWorkflow.SelfTest.ps1',
    'tools\Test-ReleaseDefender.ps1',
    'tests\persistence\WorkerRuntime.SelfTest.ps1'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $required) -PathType Leaf)) {
        $failures.Add("Required repository file is missing: $required")
    }
}

if (-not $SkipInstalledPackageCheck -and $failures.Count -eq 0) {
    $powershellExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source
    $preflightOutput = & $powershellExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Test-CodexControlOtherDevices.ps1') -Json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("Installed-package preflight failed: $($preflightOutput -join ' ')")
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Validation failed:' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" }
    exit 1
}

Write-Host 'Validation passed: PowerShell, JavaScript, clean-room runtime, package checker, persistence tests, repository files, and package preflight.' -ForegroundColor Green
