$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$module = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\persistence\modules\PersistenceIO.psm1'
Import-Module $module -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-" + [guid]::NewGuid().ToString('N'))
$outside = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-outside-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root, $outside | Out-Null
$fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()
$fixedGuid = [guid]'01234567-89ab-cdef-0123-456789abcdef'
$deterministicAdapters = @{
    UtcNow = { $fixedUtc }
    NewGuid = { $fixedGuid }
}

try {
    Invoke-CcodTest 'rejects a relative path that escapes the install root' {
        Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath '..\escape.json' } 'CCOD_PATH_OUTSIDE_ROOT'
    }

    Invoke-CcodTest 'rejects an existing junction ancestor' {
        $junction = Join-Path $root 'linked-state'
        $result = & cmd.exe /c "mklink /J `"$junction`" `"$outside`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create junction for containment test: $result" }
        Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath 'linked-state\settings.json' -AllowMissingLeaf } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'rejects a dangling reparse ancestor supplied by the item adapter' {
        $dangling = Join-Path $root 'dangling-state'
        $danglingFull = [IO.Path]::GetFullPath($dangling)
        $adapters = @{
            GetItem = {
                param([string]$Path)
                if ([IO.Path]::GetFullPath($Path) -eq $danglingFull) {
                    return [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $true }
                }
                Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
        }
        Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath 'dangling-state\settings.json' -AllowMissingLeaf -Adapters $adapters } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'writes a UTF-8 JSON object without a BOM and reads its schema' {
        $path = Join-Path $root 'state\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; automationEnabled = $false })
        $raw = [IO.File]::ReadAllBytes($path)
        Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'JSON must be UTF-8 without BOM'
        Assert-CcodEqual 1 (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').schemaVersion 'schema round-trip'
    }

    Invoke-CcodTest 'preserves ISO timestamp fields as JSON strings under Windows PowerShell' {
        $path = Join-Path $root 'state\timestamp-string.json'
        $timestamp = '2030-02-03T04:05:06.0000000Z'
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($path, "{`"schemaVersion`":1,`"updatedAtUtc`":`"$timestamp`"}", $utf8)
        $value = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings'
        Assert-CcodTrue ($value.updatedAtUtc -is [string]) 'ISO timestamp fields must remain strings after parsing'
        Assert-CcodEqual $timestamp $value.updatedAtUtc 'timestamp text must remain canonical'
    }

    Invoke-CcodTest 'atomically replaces an existing JSON file without temporary or backup leftovers' {
        $path = Join-Path $root 'replace\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' })
        $raw = [IO.File]::ReadAllBytes($path)
        $value = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings'
        $siblings = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Force)
        Assert-CcodEqual 'after' $value.value 'replacement must expose the second JSON value'
        Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'replacement JSON must remain UTF-8 without BOM'
        Assert-CcodEqual 1 $siblings.Count 'replacement must not leave temporary or backup siblings'
        Assert-CcodEqual 'settings.json' $siblings[0].Name 'replacement must leave only the target file'
    }

    Invoke-CcodTest 'atomically replaces a preclaimed empty controller result file' {
        $path = Join-Path $root 'replace-empty\controller-result.json'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        $placeholder = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $placeholder.Dispose()

        Assert-CcodEqual 0 ([IO.FileInfo]$path).Length 'preclaimed controller result starts empty'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; action = 'Recover'; ok = $true })

        $value = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'controller result'
        $siblings = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Force)
        Assert-CcodEqual 'Recover' $value.action 'replacement exposes the controller recovery action'
        Assert-CcodEqual $true ([bool]$value.ok) 'replacement exposes the controller recovery result'
        Assert-CcodEqual 1 $siblings.Count 'replacement leaves no temporary or backup siblings'
        Assert-CcodEqual 'controller-result.json' $siblings[0].Name 'replacement leaves only the controller result file'
    }


    Invoke-CcodTest 'uses the native handle commit without leftover siblings' {
        $path = Join-Path $root 'replace-native\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $nativeState = [pscustomobject]@{ Called = $false }
        $adapters = @{
            CommitFileByHandle = {
                param([IO.FileStream]$Source, [string]$Destination)
                $nativeState.Called = $true
                $errorCode = [CcodNativeAtomicFile]::MoveFileByHandle($Source.SafeFileHandle, $Destination)
                return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
            }
        }

        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters
        $siblings = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Force)
        Assert-CcodEqual $true $nativeState.Called 'existing targets must use native null-backup replacement'
        Assert-CcodEqual 'after' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'native replacement must expose the new JSON value'
        Assert-CcodEqual 1 $siblings.Count 'successful native replacement must leave no sibling artifact'
    }

    Invoke-CcodTest 'does not clobber a target that appears at the create-if-absent commit boundary' {
        $path = Join-Path $root 'create-if-absent-race\settings.json'
        $directory = Split-Path $path -Parent
        $winnerBytes = [Text.UTF8Encoding]::new($false).GetBytes("{`"schemaVersion`":1,`"value`":`"winner`"}`n")
        $raceState = [pscustomobject]@{ CompetitorCreated = $false; CommitAttempted = $false }
        $adapters = @{
            GetRandomFileName = { param([string]$Purpose) 'loser-prepared.json' }
            CommitFileByHandleNoReplace = {
                param([IO.FileStream]$Source, [string]$Destination)
                [IO.File]::WriteAllBytes($Destination, $winnerBytes)
                $raceState.CompetitorCreated = $true
                $errorCode = [CcodNativeAtomicFile]::MoveFileByHandleNoReplace($Source.SafeFileHandle, $Destination)
                $raceState.CommitAttempted = $true
                return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJsonIfAbsent -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'loser' }) -Adapters $adapters } 'CCOD_ATOMIC_TARGET_EXISTS'
        $siblings = @(Get-ChildItem -LiteralPath $directory -Force)
        Assert-CcodEqual $true $raceState.CompetitorCreated 'the competing target appears only after the loser prepared its owned file'
        Assert-CcodEqual $true $raceState.CommitAttempted 'the loser attempts a no-clobber native commit'
        Assert-CcodEqual ([Convert]::ToBase64String($winnerBytes)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'the winner bytes remain exact'
        Assert-CcodEqual 1 $siblings.Count 'the losing create leaves no temporary or recovery artifact'
        Assert-CcodEqual 'settings.json' $siblings[0].Name 'the winning target is the only sibling left'
    }

    Invoke-CcodTest 'commits only the owned replacement object when its pathname is attacked' {
        $path = Join-Path $root 'replace-source-race\settings.json'
        $directory = Split-Path $path -Parent
        $replacement = Join-Path $directory 'owned-replacement.json'
        $displaced = Join-Path $directory 'displaced-owned-replacement.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $raceState = [pscustomobject]@{
            Attempted = $false
            RenameBlocked = $false
            ForeignInserted = $false
            ForeignSourceConsumed = $false
        }
        $attemptSourceSwap = {
            param([string]$Source)
            $raceState.Attempted = $true
            try {
                [IO.File]::Move($Source, $displaced)
                [IO.File]::WriteAllText($Source, "{`"schemaVersion`":1,`"value`":`"foreign`"}`n", [Text.UTF8Encoding]::new($false))
                $raceState.ForeignInserted = $true
            } catch [IO.IOException] {
                $raceState.RenameBlocked = $true
            }
        }
        $adapters = @{
            GetRandomFileName = { param([string]$Purpose) 'owned-replacement.json' }
            ReplaceFileNoBackup = {
                param([string]$Source, [string]$Destination)
                & $attemptSourceSwap $Source
                [IO.File]::Delete($Destination)
                [IO.File]::Move($Source, $Destination)
                $raceState.ForeignSourceConsumed = $raceState.ForeignInserted -and -not [IO.File]::Exists($Source)
                return [pscustomobject]@{ Success = $true; ErrorCode = 0 }
            }
            CommitFileByHandle = {
                param([IO.FileStream]$Source, [string]$Destination)
                & $attemptSourceSwap $replacement
                $errorCode = [CcodNativeAtomicFile]::MoveFileByHandle($Source.SafeFileHandle, $Destination)
                $raceState.ForeignSourceConsumed = $raceState.ForeignInserted -and -not [IO.File]::Exists($replacement)
                return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
            }
        }

        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters
        $siblings = @(Get-ChildItem -LiteralPath $directory -Force)
        Assert-CcodEqual 'after' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'commit must not substitute foreign replacement bytes'
        Assert-CcodEqual $true $raceState.Attempted 'the source pathname attack must run after replacement bytes are written'
        Assert-CcodEqual $true $raceState.RenameBlocked 'the open owned source handle must block pathname rename'
        Assert-CcodEqual $false $raceState.ForeignInserted 'the attacker must not install a foreign source path object'
        Assert-CcodEqual $false $raceState.ForeignSourceConsumed 'commit must never consume a foreign source object'
        Assert-CcodTrue (-not [IO.File]::Exists($displaced)) 'the owned replacement object must not be displaced from its open handle'
        Assert-CcodEqual 1 $siblings.Count 'successful handle commit must leave only the target'
    }

    Invoke-CcodTest 'restores the old JSON when a simulated 1176 leaves the target missing' {
        $path = Join-Path $root 'replace-1176\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $adapters = @{
            CommitFileByHandle = {
                param([IO.FileStream]$Source, [string]$Destination)
                [IO.File]::Delete($Destination)
                return [pscustomobject]@{ Success = $false; ErrorCode = 1176 }
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_REPLACE_FAILED'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value '1176 recovery must recreate the old target JSON'
    }

    Invoke-CcodTest 'restores an empty preclaimed controller result when a simulated 1176 leaves it missing' {
        $path = Join-Path $root 'replace-empty-1176\controller-result.json'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        $placeholder = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $placeholder.Dispose()
        $adapters = @{
            CommitFileByHandle = {
                param([IO.FileStream]$Source, [string]$Destination)
                [IO.File]::Delete($Destination)
                return [pscustomobject]@{ Success = $false; ErrorCode = 1176 }
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; action = 'Recover'; ok = $true }) -Adapters $adapters } 'CCOD_ATOMIC_REPLACE_FAILED'
        Assert-CcodTrue ([IO.File]::Exists($path)) '1176 recovery must recreate the empty controller result file'
        Assert-CcodEqual 0 ([IO.FileInfo]$path).Length '1176 recovery must preserve the empty old bytes'
    }

    Invoke-CcodTest 'retains foreign path objects and writes a recovery artifact for a simulated 1177' {
        $path = Join-Path $root 'replace-1177\settings.json'
        $directory = Split-Path $path -Parent
        $displaced = Join-Path $directory 'displaced-old-target.json'
        $artifact = Join-Path $directory 'old-recovery.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'replacement') { return 'new-replacement.json' }
                return 'old-recovery.json'
            }
            CommitFileByHandle = {
                param([IO.FileStream]$Source, [string]$Destination)
                [IO.File]::Move($Destination, $displaced)
                [IO.File]::WriteAllText($Destination, 'foreign path object', [Text.UTF8Encoding]::new($false))
                return [pscustomobject]@{ Success = $false; ErrorCode = 1177 }
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_RECOVERY_FAILED'
        Assert-CcodEqual 'foreign path object' ([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))) '1177 recovery must not overwrite the foreign target object'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $displaced -ExpectedSchema 1 -Kind 'settings').value '1177 recovery must not delete or move the displaced old target object'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $artifact -ExpectedSchema 1 -Kind 'settings').value '1177 recovery artifact must retain old JSON bytes'
    }

    Invoke-CcodTest 'retains a foreign path object and writes an empty controller recovery artifact for a simulated 1177' {
        $path = Join-Path $root 'replace-empty-1177\controller-result.json'
        $directory = Split-Path $path -Parent
        $displaced = Join-Path $directory 'displaced-empty-controller-result.json'
        $artifact = Join-Path $directory 'empty-controller-recovery.json'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $placeholder = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $placeholder.Dispose()
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'replacement') { return 'new-controller-replacement.json' }
                return 'empty-controller-recovery.json'
            }
            CommitFileByHandle = {
                param([IO.FileStream]$Source, [string]$Destination)
                [IO.File]::Move($Destination, $displaced)
                [IO.File]::WriteAllText($Destination, 'foreign path object', [Text.UTF8Encoding]::new($false))
                return [pscustomobject]@{ Success = $false; ErrorCode = 1177 }
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; action = 'Recover'; ok = $true }) -Adapters $adapters } 'CCOD_ATOMIC_RECOVERY_FAILED'
        Assert-CcodEqual 'foreign path object' ([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))) '1177 recovery must not overwrite the foreign controller result object'
        Assert-CcodEqual 0 ([IO.FileInfo]$displaced).Length '1177 recovery must not modify the displaced empty controller result'
        Assert-CcodEqual 0 ([IO.FileInfo]$artifact).Length '1177 recovery artifact must retain the empty old bytes'
    }

    Invoke-CcodTest 'rejects malformed state and quarantines it beside the source' {
        $path = Join-Path $root 'state\truncated.json'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText($path, '{"schemaVersion":', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings' } 'CCOD_STATE_MALFORMED'
        $quarantined = Move-CcodCorruptState -Path $path -Reason 'truncated JSON' -Root $root -Adapters $deterministicAdapters
        Assert-CcodTrue (-not [IO.File]::Exists($path)) 'corrupt source must be moved'
        Assert-CcodTrue ([IO.File]::Exists($quarantined)) 'quarantine destination must exist'
        Assert-CcodTrue ((Split-Path $quarantined -Parent) -eq (Split-Path $path -Parent)) 'quarantine must remain beside source'
        Assert-CcodEqual 'truncated.json.corrupt.20300203T040506Z.0123456789abcdef0123456789abcdef' (Split-Path $quarantined -Leaf) 'quarantine name must use injected UTC clock and GUID'
    }

    Invoke-CcodTest 'refuses to quarantine an ordinary file outside the trusted root' {
        $path = Join-Path $outside 'unmanaged.json'
        [IO.File]::WriteAllText($path, '{', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Move-CcodCorruptState -Path $path -Reason 'outside root' -Root $root -Adapters $deterministicAdapters } 'CCOD_PATH_OUTSIDE_ROOT'
        Assert-CcodTrue ([IO.File]::Exists($path)) 'outside-root source must not be moved'
    }

    Invoke-CcodTest 'does not quarantine a file reached through a nested junction ancestor' {
        $nested = Join-Path $outside 'nested'
        New-Item -ItemType Directory -Path $nested | Out-Null
        $path = Join-Path $root 'linked-state\nested\bad.json'
        [IO.File]::WriteAllText((Join-Path $nested 'bad.json'), '{', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Move-CcodCorruptState -Path $path -Reason 'nested junction' -Root $root } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'rejects a first log entry that would exceed 2 MiB' {
        $path = Join-Path $root 'logs\oversized-first.log'
        Assert-CcodThrows { Write-CcodRotatingLog -Path $path -Message ('x' * 2MB) } 'CCOD_LOG_ENTRY_TOO_LARGE'
        Assert-CcodTrue (-not [IO.File]::Exists($path)) 'an oversized first entry must not create a log'
    }

    Invoke-CcodTest 'rolls a log before appending after the 2 MiB limit' {
        $path = Join-Path $root 'logs\supervisor.log'
        Write-CcodRotatingLog -Path $path -Message ('x' * (2MB - 2))
        Write-CcodRotatingLog -Path $path -Message 'after-rollover'
        $history = "$path.1"
        Assert-CcodTrue ([IO.File]::Exists($history)) 'a 2 MiB log must become generation 1 before the next append'
        Assert-CcodTrue ((Get-Content -LiteralPath $path -Raw) -match 'after-rollover') 'new message must be in the current log'
    }

    Invoke-CcodTest 'retains exactly ten log history files' {
        $path = Join-Path $root 'logs\retention.log'
        for ($i = 1; $i -le 11; $i++) {
            Write-CcodRotatingLog -Path $path -Message ('x' * (2MB - 2))
            Write-CcodRotatingLog -Path $path -Message "rollover-$i"
        }
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^retention\.log\.\d+$' })
        Assert-CcodEqual 10 $history.Count 'exactly ten rolled log files must remain'
        Assert-CcodTrue ([IO.File]::Exists("$path.10")) 'the oldest retained generation must be 10'
        Assert-CcodTrue (-not [IO.File]::Exists("$path.11")) 'generation 11 must be removed'
    }

    Invoke-CcodTest 'removes stale oversized and older log generations before a successful append' {
        $path = Join-Path $root 'logs\stale-history.log'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText("$path.1", ('x' * (2MB + 1)), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$path.11", 'old generation', [Text.UTF8Encoding]::new($false))
        Write-CcodRotatingLog -Path $path -Message 'safe append'
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^stale-history\.log\.\d+$' })
        Assert-CcodTrue (-not [IO.File]::Exists("$path.1")) 'oversized history generation must be removed'
        Assert-CcodTrue (-not [IO.File]::Exists("$path.11")) 'generation older than ten must be removed'
        Assert-CcodTrue (@($history | Where-Object { $_.Length -gt 2MB }).Count -eq 0) 'all retained history must be at most 2 MiB'
    }

    Invoke-CcodTest 'does not preserve an already oversized current log as history' {
        $path = Join-Path $root 'logs\oversized-current.log'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText($path, ('x' * (2MB + 1)), [Text.UTF8Encoding]::new($false))
        Write-CcodRotatingLog -Path $path -Message 'fresh bounded entry'
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^oversized-current\.log\.\d+$' })
        Assert-CcodTrue ((Get-Item -LiteralPath $path).Length -le 2MB) 'current log must be at most 2 MiB'
        Assert-CcodTrue (@($history | Where-Object { $_.Length -gt 2MB }).Count -eq 0) 'history must not retain the oversized current log'
        Assert-CcodTrue ((Get-Content -LiteralPath $path -Raw) -match 'fresh bounded entry') 'successful append must create a bounded current log'
    }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
}
