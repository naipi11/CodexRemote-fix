[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$ActivationId,
    [switch]$Prompt,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
$script:CcodActivationReceiptFields = @('schemaVersion','activationId','phase','runtimeId','previousRuntimeId','startedAtUtc','updatedAtUtc','ready','errorCode')

function Write-CcodActivationRecord {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][long]$DurationMilliseconds)
    try {
        $directory = Join-Path $InstallRoot 'logs'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $record = [ordered]@{
            schemaVersion = 1
            timestampUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            component = 'PostInstallActivation'
            activationId = $ActivationId
            submissionId = $null
            transactionId = $null
            code = $Code
            durationMilliseconds = [long][Math]::Max(0,$DurationMilliseconds)
        }
        [IO.File]::AppendAllText((Join-Path $directory 'post-install-activation.log'),(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
    } catch { }
}

function Read-CcodFinalActivationReceipt {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedActivationId)
    $path = Join-Path $Root 'state\post-install-activation.json'
    if (-not [IO.File]::Exists($path)) { throw 'CCOD_ACTIVATION_RECEIPT_MISSING' }
    try { $receipt = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    $actual = @($receipt.PSObject.Properties.Name)
    if ($actual.Count -ne $script:CcodActivationReceiptFields.Count) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    for ($index=0;$index-lt$actual.Count;$index++) { if ($actual[$index] -cne $script:CcodActivationReceiptFields[$index]) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' } }
    if ($receipt.schemaVersion -isnot [int] -or $receipt.schemaVersion -ne 1 -or
        $receipt.activationId -isnot [string] -or $receipt.activationId -cne $ExpectedActivationId -or
        $receipt.phase -isnot [string] -or $receipt.phase -cne 'Ready' -or
        $receipt.ready -isnot [bool] -or -not $receipt.ready -or $null -ne $receipt.errorCode -or
        $receipt.runtimeId -isnot [string] -or $receipt.runtimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$' -or
        ($null -ne $receipt.previousRuntimeId -and ($receipt.previousRuntimeId -isnot [string] -or $receipt.previousRuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$'))) {
        throw 'CCOD_ACTIVATION_RECEIPT_NOT_READY'
    }
    return $receipt
}

function Show-CcodActivationFailure {
    param([Parameter(Mandatory)][string]$Code)
    if (-not $Prompt -or $NoUi) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [Windows.Forms.MessageBox]::Show("CodexRemote-fix did not reach verified readiness ($Code). The previous runtime was retained for recovery; no Codex restart was attempted.",'CodexRemote-fix',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($ActivationId)) { $ActivationId = [guid]::NewGuid().ToString('D') }
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $root = [IO.Path]::GetFullPath($AppRoot)
    $stateRoot = [IO.Path]::GetFullPath($InstallRoot)
    $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
    if (-not [IO.File]::Exists($installScript)) { throw 'CCOD_ACTIVATION_INSTALL_SCRIPT_MISSING' }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    Write-CcodActivationRecord -Code 'STARTED' -DurationMilliseconds $clock.ElapsedMilliseconds
    $null = & $powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -InstallRoot $stateRoot -EnableCandidateCompatibleUpdates -ActivationId $ActivationId
    if ($LASTEXITCODE -ne 0) { throw 'CCOD_ACTIVATION_RUNTIME_FAILED' }
    $activationReceipt = Read-CcodFinalActivationReceipt -Root $stateRoot -ExpectedActivationId $ActivationId
    Write-CcodActivationRecord -Code 'RUNTIME_ACTIVATED' -DurationMilliseconds $clock.ElapsedMilliseconds
} catch {
    $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
    $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_ACTIVATION_FAILED' }
    Write-CcodActivationRecord -Code $code -DurationMilliseconds $clock.ElapsedMilliseconds
    Show-CcodActivationFailure -Code $code
    Write-Error $code -ErrorAction Continue
    exit 1
}

if ($Prompt) {
    $restartConfirmed = $false
    try {
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        if ([IO.File]::Exists($promptScript)) {
            $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$promptScript,'-AppRoot',$root,'-InstallRoot',$stateRoot,'-ActivationId',$ActivationId)
            if ($NoUi) { $arguments += '-NoUi' }
            $null = & $powershell @arguments
            $restartConfirmed = ($LASTEXITCODE -eq 0)
        }
    } catch { $restartConfirmed = $false }
    if (-not $restartConfirmed) {
        Write-CcodActivationRecord -Code 'RESTART_UNCONFIRMED' -DurationMilliseconds $clock.ElapsedMilliseconds
        exit 0
    }
}

Write-CcodActivationRecord -Code 'COMPLETED' -DurationMilliseconds $clock.ElapsedMilliseconds
exit 0
