[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$ActivationId,
    [switch]$ValidateReceiptOnly,
    [switch]$ValidateReceiptWithTimeout,
    [ValidateRange(1,300000)][int]$ValidationTimeoutMilliseconds = 2000,
    [ValidateRange(1,300000)][int]$FirstReceiptTimeoutMilliseconds = 90000,
    [ValidateRange(1,300000)][int]$ActivationTimeoutMilliseconds = 300000,
    [switch]$Prompt,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
$script:CcodActivationReceiptFields = @('schemaVersion','activationId','phase','runtimeId','previousRuntimeId','startedAtUtc','updatedAtUtc','ready','errorCode')
$script:CcodActivationReceiptPhases = @('StoppingPreviousRuntime','InstallingRuntime','ActivatingRuntime','StartingProtection','Ready','Failed')
$script:CcodActivationReceiptMaximumBytes = 16384

function Test-CcodCanonicalGuid {
    param($Value)
    $parsed = [guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodCanonicalUtc {
    param($Value)
    $parsed = [DateTime]::MinValue
    return $Value -is [string] -and
        [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

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

function Assert-CcodActivationReceiptPathSafe {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $prefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    if (-not ($canonicalPath -ceq $canonicalRoot -or $canonicalPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
    }
    $current = $canonicalPath
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
        }
        if ($current -ceq $canonicalRoot) { break }
        $parent = Split-Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) {
            throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
        }
        $current = $parent
    }
}

function Read-CcodTerminalActivationReceipt {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedActivationId)
    $path = Join-Path $Root 'state\post-install-activation.json'
    if (-not [IO.File]::Exists($path)) { throw 'CCOD_ACTIVATION_RECEIPT_MISSING' }
    try {
        Assert-CcodActivationReceiptPathSafe -Root $Root -Path $path
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -le 0 -or $item.Length -gt $script:CcodActivationReceiptMaximumBytes) { throw 'invalid receipt file' }
        $content = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
        if ($content.TrimStart()[0] -cne '{' -or $content.TrimEnd()[-1] -cne '}') { throw 'receipt is not one object' }
        $receipt = $content | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    if ($receipt -isnot [pscustomobject]) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    $actual = @($receipt.PSObject.Properties.Name)
    if ($actual.Count -ne $script:CcodActivationReceiptFields.Count) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    for ($index=0;$index-lt$actual.Count;$index++) { if ($actual[$index] -cne $script:CcodActivationReceiptFields[$index]) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' } }
    if ($receipt.schemaVersion -isnot [int] -or $receipt.schemaVersion -ne 1 -or
        -not (Test-CcodCanonicalGuid $receipt.activationId) -or $receipt.activationId -cne $ExpectedActivationId -or
        $receipt.phase -isnot [string] -or $script:CcodActivationReceiptPhases -cnotcontains $receipt.phase -or
        $receipt.ready -isnot [bool] -or
        ($null -ne $receipt.runtimeId -and ($receipt.runtimeId -isnot [string] -or $receipt.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
        ($null -ne $receipt.previousRuntimeId -and ($receipt.previousRuntimeId -isnot [string] -or $receipt.previousRuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
        -not (Test-CcodCanonicalUtc $receipt.startedAtUtc) -or -not (Test-CcodCanonicalUtc $receipt.updatedAtUtc)) {
        throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
    }
    $started = [DateTime]::ParseExact($receipt.startedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $updated = [DateTime]::ParseExact($receipt.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if ($updated -lt $started -or
        ($receipt.phase -ceq 'Ready' -and ($receipt.runtimeId -isnot [string] -or -not $receipt.ready -or $null -ne $receipt.errorCode)) -or
        ($receipt.phase -ceq 'Failed' -and ($receipt.ready -or $receipt.errorCode -isnot [string] -or $receipt.errorCode -cnotmatch '^CCOD_[A-Z0-9_]{1,96}$')) -or
        ($receipt.phase -cnotin @('Ready','Failed') -and ($receipt.ready -or $null -ne $receipt.errorCode))) {
        throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
    }
    return $receipt
}

function ConvertTo-CcodNativeProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') { $slashes++; continue }
        if ($character -eq [char]'"') {
            [void]$quoted.Append(('\' * (($slashes * 2) + 1)))
            [void]$quoted.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$quoted.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$quoted.Append($character)
    }
    if ($slashes -gt 0) { [void]$quoted.Append(('\' * ($slashes * 2))) }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Stop-CcodOwnedInstallProcess {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    $boundedStopProven = $false
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        $boundedStopProven = $Process.WaitForExit(5000) -and $Process.HasExited
    } catch { }
    if ($boundedStopProven) { return }
    while ($true) {
        try {
            if (-not $Process.HasExited) { $Process.Kill() }
            [void]$Process.WaitForExit()
            if ($Process.HasExited) { return }
        } catch { }
        [Threading.Thread]::Sleep(100)
    }
}

function Invoke-CcodOwnedInstallWorker {
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$InstallScript,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][int]$FirstReceiptTimeout,
        [Parameter(Mandatory)][int]$ActivationTimeout
    )
    $process = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $firstReceiptObserved = $false
    try {
        $arguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $InstallScript,
            '-InstallRoot',
            $StateRoot,
            '-EnableCandidateCompatibleUpdates',
            '-ActivationId',
            $ActivationId
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $PowerShellPath
        $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CcodNativeProcessArgument ([string]$_) }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'CCOD_ACTIVATION_WORKER_START_FAILED' }
        while (-not $process.HasExited) {
            if (-not $firstReceiptObserved) {
                try {
                    $null = Read-CcodTerminalActivationReceipt -Root $StateRoot -ExpectedActivationId $ActivationId
                    $firstReceiptObserved = $true
                } catch { }
            }
            if (-not $firstReceiptObserved -and $clock.ElapsedMilliseconds -ge $FirstReceiptTimeout) {
                Stop-CcodOwnedInstallProcess -Process $process
                throw 'CCOD_ACTIVATION_FIRST_RECEIPT_TIMEOUT'
            }
            if ($clock.ElapsedMilliseconds -ge $ActivationTimeout) {
                Stop-CcodOwnedInstallProcess -Process $process
                throw 'CCOD_ACTIVATION_TIMEOUT'
            }
            [void]$process.WaitForExit(50)
        }
        [void]$process.WaitForExit()
        return [int]$process.ExitCode
    } finally {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) { Stop-CcodOwnedInstallProcess -Process $process }
            } finally {
                $process.Dispose()
            }
        }
    }
}

function Invoke-CcodBoundedReceiptValidator {
    param([Parameter(Mandatory)][int]$TimeoutMilliseconds)
    $process = $null
    try {
        $hostExecutable = Join-Path $PSHOME 'powershell.exe'
        if (-not [IO.File]::Exists($hostExecutable) -or -not [IO.File]::Exists($PSCommandPath)) {
            throw 'CCOD_ACTIVATION_VALIDATOR_START_FAILED'
        }
        $arguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $PSCommandPath,
            '-AppRoot',
            $AppRoot,
            '-InstallRoot',
            $InstallRoot,
            '-ValidateReceiptOnly',
            '-ActivationId',
            $ActivationId
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $hostExecutable
        $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CcodNativeProcessArgument ([string]$_) }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'CCOD_ACTIVATION_VALIDATOR_START_FAILED' }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
            } catch { }
            Write-Error 'CCOD_ACTIVATION_VALIDATOR_TIMEOUT' -ErrorAction Continue
            return 3
        }
        $exitCode = [int]$process.ExitCode
        if ($exitCode -eq 0 -or $exitCode -eq 2) { return $exitCode }
        Write-Error 'CCOD_ACTIVATION_RECEIPT_INVALID' -ErrorAction Continue
        return 3
    } catch {
        Write-Error 'CCOD_ACTIVATION_VALIDATOR_START_FAILED' -ErrorAction Continue
        return 3
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Read-CcodFinalActivationReceipt {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedActivationId)
    $receipt = Read-CcodTerminalActivationReceipt -Root $Root -ExpectedActivationId $ExpectedActivationId
    if ($receipt.phase -cne 'Ready') { throw 'CCOD_ACTIVATION_RECEIPT_NOT_READY' }
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

if ($ValidateReceiptOnly -and $ValidateReceiptWithTimeout) { Write-Error 'CCOD_ACTIVATION_VALIDATOR_MODE_INVALID' -ErrorAction Continue; exit 3 }
if ([string]::IsNullOrWhiteSpace($ActivationId)) {
    if ($ValidateReceiptOnly -or $ValidateReceiptWithTimeout) { Write-Error 'CCOD_ACTIVATION_ID_INVALID' -ErrorAction Continue; exit 3 }
    $ActivationId = [guid]::NewGuid().ToString('D')
}
if (-not (Test-CcodCanonicalGuid $ActivationId)) { Write-Error 'CCOD_ACTIVATION_ID_INVALID' -ErrorAction Continue; exit 3 }
if ($FirstReceiptTimeoutMilliseconds -gt $ActivationTimeoutMilliseconds) { Write-Error 'CCOD_ACTIVATION_TIMEOUT_INVALID' -ErrorAction Continue; exit 3 }
if ($ValidateReceiptWithTimeout) {
    $validationResult = Invoke-CcodBoundedReceiptValidator -TimeoutMilliseconds $ValidationTimeoutMilliseconds
    exit $validationResult
}
if ($ValidateReceiptOnly) {
    try {
        $terminalReceipt = Read-CcodTerminalActivationReceipt -Root ([IO.Path]::GetFullPath($InstallRoot)) -ExpectedActivationId $ActivationId
        if ($terminalReceipt.phase -ceq 'Ready') { exit 0 }
        if ($terminalReceipt.phase -ceq 'Failed') { exit 2 }
        throw 'CCOD_ACTIVATION_RECEIPT_NOT_READY'
    } catch {
        $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
        $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_ACTIVATION_RECEIPT_INVALID' }
        Write-Error $code -ErrorAction Continue
        exit 3
    }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $root = [IO.Path]::GetFullPath($AppRoot)
    $stateRoot = [IO.Path]::GetFullPath($InstallRoot)
    $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
    if (-not [IO.File]::Exists($installScript)) { throw 'CCOD_ACTIVATION_INSTALL_SCRIPT_MISSING' }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    Write-CcodActivationRecord -Code 'STARTED' -DurationMilliseconds $clock.ElapsedMilliseconds
    $installExitCode = Invoke-CcodOwnedInstallWorker -PowerShellPath $powershell -InstallScript $installScript -StateRoot $stateRoot -FirstReceiptTimeout $FirstReceiptTimeoutMilliseconds -ActivationTimeout $ActivationTimeoutMilliseconds
    if ($installExitCode -ne 0) {
        $reportedErrorCode = $null
        try {
            $failedReceipt = Read-CcodTerminalActivationReceipt -Root $stateRoot -ExpectedActivationId $ActivationId
            if ($failedReceipt.phase -ceq 'Failed') { $reportedErrorCode = [string]$failedReceipt.errorCode }
        } catch { }
        if ($reportedErrorCode -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { throw $reportedErrorCode }
        throw 'CCOD_ACTIVATION_RUNTIME_FAILED'
    }
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
