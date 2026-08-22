[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [switch]$Prompt,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'

function Write-CcodActivationRecord {
    param([Parameter(Mandatory)][string]$Code)
    try {
        $directory = Join-Path $InstallRoot 'logs'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $record = [ordered]@{
            schemaVersion = 1
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            component = 'PostInstallActivation'
            code = $Code
        }
        [IO.File]::AppendAllText(
            (Join-Path $directory 'post-install-activation.log'),
            (($record | ConvertTo-Json -Compress) + "`n"),
            [Text.UTF8Encoding]::new($false)
        )
    } catch {
    }
}

function Show-CcodActivationFailure {
    if (-not $Prompt -or $NoUi) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [Windows.Forms.MessageBox]::Show(
            'CodexRemote-fix could not activate the new runtime. The existing runtime was left unchanged; no Codex restart was attempted.',
            'CodexRemote-fix',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
    }
}

try {
    $root = [IO.Path]::GetFullPath($AppRoot)
    $stateRoot = [IO.Path]::GetFullPath($InstallRoot)
    $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
    if (-not [IO.File]::Exists($installScript)) { throw 'CCOD_ACTIVATION_INSTALL_SCRIPT_MISSING' }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source

    Write-CcodActivationRecord -Code 'STARTED'
    $null = & $powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -InstallRoot $stateRoot -EnableCandidateCompatibleUpdates 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'CCOD_ACTIVATION_RUNTIME_FAILED' }
    Write-CcodActivationRecord -Code 'RUNTIME_ACTIVATED'

} catch {
    Write-CcodActivationRecord -Code 'FAILED'
    Show-CcodActivationFailure
    exit 1
}

if ($Prompt) {
    $restartConfirmed = $false
    try {
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        if ([IO.File]::Exists($promptScript)) {
            $null = & $powershell -NoProfile -ExecutionPolicy Bypass -File $promptScript -AppRoot $root -InstallRoot $stateRoot 2>$null
            $restartConfirmed = ($LASTEXITCODE -eq 0)
        }
    } catch {
        $restartConfirmed = $false
    }
    if (-not $restartConfirmed) {
        Write-CcodActivationRecord -Code 'RESTART_UNCONFIRMED'
        exit 0
    }
}

Write-CcodActivationRecord -Code 'COMPLETED'
exit 0
