[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [string]$InstallRoot,
    [ValidateSet('Restart','Later')][string]$Choice,
    [string]$ActivationId,
    [switch]$Preview,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
$script:CcodRestartSubmissionReceiptFields = @('schemaVersion','submissionId','accepted','transactionId','errorCode','completedAtUtc')

function Test-CcodRestartCanonicalGuid {
    param($Value)
    $parsed = [guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodRestartCanonicalUtc {
    param($Value)
    $parsed = [DateTime]::MinValue
    return $Value -is [string] -and
        [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Assert-CcodRestartSubmissionReceipt {
    param($Receipt)
    if ($Receipt -isnot [pscustomobject]) { throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Lifecycle submission receipt is invalid.'),'CCOD_RESTART_RECEIPT_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null) }
    $actual = @($Receipt.PSObject.Properties.Name)
    if (($actual -join "`0") -cne ($script:CcodRestartSubmissionReceiptFields -join "`0") -or
        @($Receipt.PSObject.Properties | Where-Object { $_.MemberType -notin @('NoteProperty','Property') }).Count -ne 0 -or
        $Receipt.schemaVersion -isnot [int] -or $Receipt.schemaVersion -ne 1 -or
        -not (Test-CcodRestartCanonicalGuid $Receipt.submissionId) -or $Receipt.accepted -isnot [bool] -or
        -not (Test-CcodRestartCanonicalUtc $Receipt.completedAtUtc) -or
        ($Receipt.accepted -and (-not (Test-CcodRestartCanonicalGuid $Receipt.transactionId) -or $null -ne $Receipt.errorCode)) -or
        (-not $Receipt.accepted -and ($null -ne $Receipt.transactionId -or $Receipt.errorCode -isnot [string] -or $Receipt.errorCode -cnotmatch '^CCOD_[A-Z0-9_]{1,96}$'))) {
        throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Lifecycle submission receipt is invalid.'),'CCOD_RESTART_RECEIPT_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
    }
    return $Receipt
}

function Get-CcodRestartPromptText {
    [pscustomobject][ordered]@{
        Title = 'CodexRemote-fix'
        Message = "Codex must be restarted for the fix to take effect.`r`n`r`nRestart Codex now?`r`nChoose Yes to restart now, or No to restart it manually later."
    }
}

function Show-CcodRestartPrompt {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $text = Get-CcodRestartPromptText
    $result = [Windows.Forms.MessageBox]::Show($text.Message,$text.Title,[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information,[Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($result -eq [Windows.Forms.DialogResult]::Yes) { return 'Restart' }
    return 'Later'
}

function Show-CcodRestartFailure {
    param([Parameter(Mandatory)][string]$Code)
    if ($NoUi) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [Windows.Forms.MessageBox]::Show("Codex could not be restarted automatically ($Code). Please restart Codex manually.",'CodexRemote-fix',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
}

function Resolve-CcodRestartLifecycle {
    param([Parameter(Mandatory)][string]$CheckoutRoot,[Parameter(Mandatory)][string]$Root)
    $manifestModule = [IO.Path]::GetFullPath((Join-Path $CheckoutRoot 'src\persistence\modules\RuntimeManifest.psm1'))
    if (-not [IO.File]::Exists($manifestModule)) { throw 'CCOD_RESTART_SUPPORT_MISSING' }
    Import-Module $manifestModule -Force
    if (-not [IO.File]::Exists((Join-Path $Root 'active.json'))) { throw 'CCOD_INSTALL_REQUIRED' }
    $active = Read-CcodActiveRuntime -InstallRoot $Root
    $runtime = [IO.Path]::GetFullPath((Join-Path (Join-Path $Root 'runtime') $active.activeRuntime))
    $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $active.activeRuntime
    if (-not $validation.Valid) { throw 'CCOD_RESTART_RUNTIME_INVALID' }
    $modulePath = [IO.Path]::GetFullPath((Join-Path $runtime 'src\persistence\modules\LifecycleRequest.psm1'))
    if (-not [IO.File]::Exists($modulePath)) { throw 'CCOD_RESTART_SUPPORT_MISSING' }
    [pscustomobject][ordered]@{ RuntimeId=[string]$active.activeRuntime;Generation=[UInt64]$active.generation;ModulePath=$modulePath }
}

function Submit-CcodRestartLifecycle {
    param([Parameter(Mandatory)]$Resolved,[Parameter(Mandatory)][string]$Root)
    Import-Module $Resolved.ModulePath -Force
    Submit-CcodLifecycleRequest -InstallRoot $Root -Kind RestartAndRepair -Origin Installer -RuntimeId $Resolved.RuntimeId -RuntimeGeneration ([UInt64]$Resolved.Generation) -TimeoutMilliseconds 5000
}

function Write-CcodRestartRecord {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CurrentActivationId,
        [AllowNull()]$SubmissionId,
        [AllowNull()]$TransactionId,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][long]$DurationMilliseconds
    )
    try {
        $directory = Join-Path $Root 'logs'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $record = [ordered]@{
            schemaVersion = 1
            timestampUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            component = 'PostInstallRestart'
            activationId = $CurrentActivationId
            submissionId = $SubmissionId
            transactionId = $TransactionId
            code = $Code
            durationMilliseconds = [long][Math]::Max(0,$DurationMilliseconds)
        }
        [IO.File]::AppendAllText((Join-Path $directory 'post-install-activation.log'),(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
    } catch { }
}

$previewText = if ($Preview) { Get-CcodRestartPromptText } else { $null }
if ($null -ne $previewText) { Write-Output $previewText.Message; exit 0 }

$selected = if ([string]::IsNullOrWhiteSpace($Choice)) { Show-CcodRestartPrompt } else { $Choice }
if ($selected -ceq 'Later') { exit 0 }

if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices' }
if ([string]::IsNullOrWhiteSpace($ActivationId)) { $ActivationId = [guid]::NewGuid().ToString('D') }
$clock = [Diagnostics.Stopwatch]::StartNew()
$receipt = $null
try {
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $app = [IO.Path]::GetFullPath($AppRoot)
    $resolved = Resolve-CcodRestartLifecycle -CheckoutRoot $app -Root $root
    $untrustedReceipt = Submit-CcodRestartLifecycle -Resolved $resolved -Root $root
    $receipt = Assert-CcodRestartSubmissionReceipt -Receipt $untrustedReceipt
    if (-not $receipt.accepted) {
        $code = [string]$receipt.errorCode
        Write-CcodRestartRecord -Root $root -CurrentActivationId $ActivationId -SubmissionId $(if($null-ne$receipt){$receipt.submissionId}else{$null}) -TransactionId $(if($null-ne$receipt){$receipt.transactionId}else{$null}) -Code $code -DurationMilliseconds $clock.ElapsedMilliseconds
        Show-CcodRestartFailure -Code $code
        Write-Error $code -ErrorAction Continue
        exit 1
    }
    Write-CcodRestartRecord -Root $root -CurrentActivationId $ActivationId -SubmissionId $receipt.submissionId -TransactionId $receipt.transactionId -Code 'RESTART_SUBMITTED' -DurationMilliseconds $clock.ElapsedMilliseconds
    exit 0
} catch {
    $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
    $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_RESTART_SUBMISSION_FAILED' }
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        try { Write-CcodRestartRecord -Root ([IO.Path]::GetFullPath($InstallRoot)) -CurrentActivationId $ActivationId -SubmissionId $(if($null-ne$receipt){$receipt.submissionId}else{$null}) -TransactionId $(if($null-ne$receipt){$receipt.transactionId}else{$null}) -Code $code -DurationMilliseconds $clock.ElapsedMilliseconds } catch { }
    }
    Show-CcodRestartFailure -Code $code
    Write-Error $code -ErrorAction Continue
    exit 1
}
