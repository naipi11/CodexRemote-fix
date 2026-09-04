Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Throw-CcodCleanReleaseRunnerError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target)
}

function Get-CcodCleanReleaseRunnerInstallRootPresent {
    param([Parameter(Mandatory)][string]$InstallRoot)
    try {
        Get-Item -LiteralPath $InstallRoot -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) {
            return $false
        }
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect the installation root.' $InstallRoot
    }
}

function Get-CcodCleanReleaseRunnerDefaultAdapters {
    @{
        GetPackageVersion = {
            param($Root)
            $package = Join-Path $Root 'package.json'
            $json = [IO.File]::ReadAllText($package, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            [string]$json.version
        }
        GetGitPorcelain = {
            param($Root)
            try {
                $status = @(& git -C $Root status --porcelain --untracked-files=all --ignored=matching 2>$null)
                if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
                @($status | ForEach-Object { [string]$_ }) -join "`n"
            } catch {
                Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect the repository status.' $Root
            }
        }
        GetGitCommit = {
            param($Root)
            try {
                $commit = ([string](& git -C $Root rev-parse HEAD 2>$null)).Trim().ToLowerInvariant()
                if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'git commit failed' }
                $commit
            } catch {
                Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect the repository commit.' $Root
            }
        }
        GetProductState = {
            param($Root)
            $installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
            $installPresent = Get-CcodCleanReleaseRunnerInstallRootPresent -InstallRoot $installRoot
            $taskPresent = $false
            try {
                $task = Get-ScheduledTask -TaskName 'Codex Control Other Devices Supervisor' -ErrorAction Stop
                $taskPresent = $null -ne $task
            } catch {
                if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) {
                    $taskPresent = $false
                } else {
                    Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect scheduled tasks.' $Root
                }
            }
            $names = @('CodexRemote.fix.TrayHost','CodexRemote.TrayHost','CodexRemote-fix','CodexControlOtherDevices')
            try {
                $running = @(Get-Process -ErrorAction Stop | Where-Object { $names -contains $_.ProcessName })
            } catch {
                Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect running product processes.' $Root
            }
            [pscustomobject]@{
                InstallRootPresent = [bool]$installPresent
                ScheduledTaskPresent = [bool]$taskPresent
                SupervisorPresent = [bool](@($running | Where-Object { $_.ProcessName -cne 'CodexRemote.fix.TrayHost' -and $_.ProcessName -cne 'CodexRemote.TrayHost' }).Count -gt 0)
                TrayHostPresent = [bool](@($running | Where-Object { $_.ProcessName -ceq 'CodexRemote.fix.TrayHost' -or $_.ProcessName -ceq 'CodexRemote.TrayHost' }).Count -gt 0)
            }
        }
        ProbeMutex = {
            param($Kind)
            $mutex = $null
            try {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                try {
                    $sid = $identity.User.Value
                } finally {
                    $identity.Dispose()
                }
                $name = "Global\CodexControlOtherDevices.$Kind.$sid"
                $opened = [Threading.Mutex]::TryOpenExisting($name, [ref]$mutex)
                return [bool]$opened
            } catch {
                Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' "Clean runner could not inspect the $Kind mutex." $Kind
            } finally {
                if ($null -ne $mutex) { $mutex.Dispose() }
            }
        }
        WritePreflightEvidence = {
            param($Path, $Record)
            $json = (($Record | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            $encoding = [Text.UTF8Encoding]::new($false)
            $bytes = $encoding.GetBytes($json)
            $stream = $null
            try {
                $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } catch {
                Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_PREFLIGHT_WRITE_FAILED' 'Clean preflight evidence is create-only and could not be written.' $Path
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
            try {
                $readback = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
                if ($readback -cne $json) { throw 'preflight readback mismatch' }
            } catch {
                Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_PREFLIGHT_WRITE_FAILED' 'Clean preflight evidence failed strict readback.' $Path
            }
            $Path
        }
        CleanupProduct = {
            param($Root)
            Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_CONTAMINATED' 'Clean runner never cleans product state.' $Root
        }
    }
}

function Resolve-CcodCleanReleaseRunnerAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodCleanReleaseRunnerDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in @($Adapters.Keys)) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_ADAPTER_INVALID' 'Private clean runner adapters must replace known scriptblock operations only.' $name
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Test-CcodCleanReleaseRunnerCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$ExpectedVersion,
        [hashtable]$Adapters
    )
    $adapters = Resolve-CcodCleanReleaseRunnerAdapters $Adapters
    try {
        $root = [IO.Path]::GetFullPath($RepositoryRoot)
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'unsafe root' }
    } catch {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_ROOT_INVALID' 'Clean runner requires an existing non-reparse repository directory.' $RepositoryRoot
    }
    try {
        $version = [string](& $adapters.GetPackageVersion $root)
    } catch {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect package metadata.' $root
    }
    if ([string]::IsNullOrWhiteSpace($version) -or $version -cne $ExpectedVersion) {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_VERSION_INVALID' 'Repository version does not match the expected clean-runner version.' $version
    }
    try {
        $porcelain = [string](& $adapters.GetGitPorcelain $root)
    } catch {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect the repository status.' $root
    }
    if (-not [string]::IsNullOrWhiteSpace($porcelain)) {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_DIRTY' 'Clean runner requires an empty git status.' $porcelain
    }
    try {
        $product = & $adapters.GetProductState $root
    } catch {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect installed product state.' $root
    }
    if ([bool]$product.InstallRootPresent -or [bool]$product.ScheduledTaskPresent -or [bool]$product.SupervisorPresent -or [bool]$product.TrayHostPresent) {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_CONTAMINATED' 'Installed product state is present; clean runner performs no cleanup.' $root
    }
    foreach ($kind in @('AccountTransition','AccountSupervisor')) {
        try {
            $occupied = [bool](& $adapters.ProbeMutex $kind)
        } catch {
            Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' "Clean runner could not inspect the $kind mutex." $kind
        }
        if ($occupied) {
            Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_CONTAMINATED' "Occupied $kind mutex; clean runner performs no cleanup." $kind
        }
    }
    try {
        $commit = [string](& $adapters.GetGitCommit $root)
    } catch {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED' 'Clean runner could not inspect the repository commit.' $root
    }
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_COMMIT_INVALID' 'Clean runner received an invalid repository commit.' $commit
    }
    $commit = $commit.ToLowerInvariant()
    $record = [ordered]@{
        schemaVersion = 1
        valid = $true
        version = $ExpectedVersion
        gitCommit = $commit
        repositoryRoot = $root
    }
    $evidencePath = Join-Path $root ("CodexRemote-fix-$ExpectedVersion-clean-preflight.json")
    try {
        $path = & $adapters.WritePreflightEvidence $evidencePath $record
    } catch {
        Throw-CcodCleanReleaseRunnerError 'CCOD_CLEAN_RUNNER_PREFLIGHT_WRITE_FAILED' 'Clean preflight evidence could not be published.' $evidencePath
    }
    return [pscustomobject][ordered]@{
        Valid = $true
        Version = $ExpectedVersion
        GitCommit = $commit
        RepositoryRoot = $root
        PreflightPath = $path
    }
}

function Test-CcodCleanReleaseRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$ExpectedVersion
    )
    Test-CcodCleanReleaseRunnerCore -RepositoryRoot $RepositoryRoot -ExpectedVersion $ExpectedVersion
}

Export-ModuleMember -Function Test-CcodCleanReleaseRunner
