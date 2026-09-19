$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
$installLifecycleModule = Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\InstallLifecycle.psm1') -PassThru
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleEpoch.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\InstallFileTransaction.psm1')
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-runtime-manifest-" + [guid]::NewGuid().ToString('N'))
$outside = Join-Path ([IO.Path]::GetTempPath()) ("ccod-runtime-outside-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root, $outside | Out-Null

function New-CcodRuntimeFixture {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectVersion,
        [Parameter(Mandatory)][string]$AContent,
        [Parameter(Mandatory)][string]$BContent
    )

    $staging = Join-Path $InstallRoot 'staging'
    New-Item -ItemType Directory -Path $staging | Out-Null
    [IO.File]::WriteAllText((Join-Path $staging 'b.txt'), $BContent, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $staging 'a.txt'), $AContent, [Text.UTF8Encoding]::new($false))
    $manifest = New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion $ProjectVersion
    $runtime = Join-Path (Join-Path $InstallRoot 'runtime') $manifest.runtimeId
    [IO.Directory]::CreateDirectory((Split-Path $runtime -Parent)) | Out-Null
    [IO.Directory]::Move($staging, $runtime)
    Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest
    return [pscustomobject]@{ Runtime = $runtime; Manifest = $manifest }
}

function Set-CcodTestActiveRuntime {
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$NewRuntimeId, [hashtable]$Adapters)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $ownership = $null
    try {
        $current = if ([IO.File]::Exists((Join-Path $InstallRoot 'active.json'))) { Read-CcodActiveRuntime -InstallRoot $InstallRoot } else { $null }
        $owner = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
        $ownership = Enter-CcodLifecycleOwnership -InstallRoot $InstallRoot -RuntimeId $(if ($null -eq $current) { $NewRuntimeId } else { $current.activeRuntime }) -RuntimeGeneration $(if ($null -eq $current) { [UInt64]1 } else { [UInt64]$current.generation }) -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
        return Invoke-CcodRuntimeCoreSet -InstallRoot $InstallRoot -NewRuntimeId $NewRuntimeId -Ownership $ownership -Adapters $Adapters
    } finally {
        if ($null -ne $ownership -and -not $ownership.released) { Exit-CcodLifecycleOwnership -Ownership $ownership | Out-Null }
        $process.Dispose(); $identity.Dispose()
    }
}

function Invoke-CcodRuntimeCoreSet {
    param([Parameter(Mandatory)][string]$InstallRoot,[string]$NewRuntimeId,$TargetGeneration,$FileTransaction,$Ownership,[hashtable]$Adapters)
    $module = Get-Module -Name RuntimeManifest
    return & $module { param($Root,$Runtime,$Generation,$Transaction,$Lease,$Injected) Set-CcodActiveRuntimeCore -InstallRoot $Root -NewRuntimeId $Runtime -TargetGeneration $Generation -FileTransaction $Transaction -Ownership $Lease -Adapters $Injected } $InstallRoot $NewRuntimeId $TargetGeneration $FileTransaction $Ownership $Adapters
}

try {
    Invoke-CcodTest 'runtime manifest file records preserve strict property order' {
        $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'src/persistence/modules/RuntimeManifest.psm1'), [Text.UTF8Encoding]::new($false))
        Assert-CcodTrue ($source.Contains('$records.Add([pscustomobject][ordered]@{')) 'runtime file records use deterministic property order'
    }

    Invoke-CcodTest 'runtime root existence probe preserves lookup failures' {
        $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'src/persistence/modules/RuntimeManifest.psm1'), [Text.UTF8Encoding]::new($false))
        $start = $source.IndexOf('function Get-CcodRuntimeRoot')
        $end = $source.IndexOf('function Get-CcodRuntimeFileSha256')
        Assert-CcodTrue ($start -ge 0 -and $end -gt $start) 'runtime root helper is present as one inspectable definition'
        $body = $source.Substring($start, $end - $start)
        Assert-CcodTrue (-not $body.Contains('[IO.Directory]::Exists($root)')) 'runtime root does not collapse access failures through Directory.Exists'
        Assert-CcodTrue ($body.Contains('catch [Management.Automation.ItemNotFoundException]')) 'runtime root handles only an explicit missing-item exception as absence'
        $manifestStart = $source.IndexOf('function Test-CcodRuntimeManifest')
        $manifestEnd = $source.IndexOf('function Get-CcodRuntimeDirectoryForId')
        Assert-CcodTrue ($manifestStart -ge 0 -and $manifestEnd -gt $manifestStart) 'runtime manifest validator is present as one inspectable definition'
        Assert-CcodTrue (-not $source.Substring($manifestStart, $manifestEnd - $manifestStart).Contains("'^[0-9a-f]{64}$'")) 'runtime manifest hash validation uses an absolute end anchor'
        }

    Invoke-CcodTest 'runtime root propagates an injected access failure instead of treating it as missing' {
        $module = Get-Module -Name RuntimeManifest
        Assert-CcodTrue ($null -ne $module) 'RuntimeManifest module is loaded for the behavioral probe'
        try {
            $error = & $module {
                function Get-Item { throw [UnauthorizedAccessException]::new('fixture access denied') }
                try {
                    Get-CcodRuntimeRoot -RuntimeDirectory ([IO.Path]::GetFullPath((Join-Path $root 'access-denied')))
                    return $null
                } catch {
                    return $_
                } finally {
                    Remove-Item -LiteralPath Function:\Get-Item -Force -ErrorAction SilentlyContinue
                }
            }
            Assert-CcodTrue ($null -ne $error -and $error.Exception -is [UnauthorizedAccessException]) 'access failures escape the runtime-root probe'
        } finally {
            Remove-Item -LiteralPath Function:\Get-Item -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-CcodTest 'public active runtime setter does not expose adapter injection' {
        $command = Get-Command Set-CcodActiveRuntime -Module RuntimeManifest
        Assert-CcodTrue (-not $command.Parameters.ContainsKey('Adapters')) 'public active runtime mutation cannot replace lifecycle fence adapters'
    }

    Invoke-CcodTest 'includes the External renderer integration module in the staged runtime manifest input' {
        $sourceFiles = @(& $installLifecycleModule { param($sourceRoot) Get-CcodLifecycleSourceFiles -SourceRoot $sourceRoot } $repositoryRoot)
        $rendererModule = @($sourceFiles | Where-Object { $_.Relative -ceq 'src\persistence\modules\RendererIntegration.psm1' })

        Assert-CcodEqual 1 $rendererModule.Count 'External renderer integration module must be copied into every staged runtime'
        Assert-CcodTrue ([IO.File]::Exists($rendererModule[0].Source)) 'External renderer integration manifest input must resolve to a regular source file'
    }

    Invoke-CcodTest 'creates a stable sorted manifest that excludes itself' {
        $runtime = Join-Path $root 'standalone'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'b.txt'), 'beta', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $runtime 'a.txt'), 'alpha', [Text.UTF8Encoding]::new($false))

        $first = New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0'
        Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $first
        $second = New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0'

        Assert-CcodTrue ($first.runtimeId -cmatch '^2\.0\.0-[0-9a-f]{16}-[0-9a-f]{32}$') 'runtime ID binds project version, file digest, and nonce'
        Assert-CcodTrue ($first.runtimeId -cne $second.runtimeId) 'the same runtime bytes receive unique per-attempt nonces'
        Assert-CcodEqual (($first.runtimeId -split '-')[-2]) (($second.runtimeId -split '-')[-2]) 'identical sorted file records retain the same deterministic digest'
        Assert-CcodEqual 'a.txt' $first.files[0].path 'files must sort ordinally'
        Assert-CcodEqual 'b.txt' $first.files[1].path 'files must sort ordinally'
        Assert-CcodEqual 2 $first.files.Count 'manifest must exclude manifest.json itself'
        Assert-CcodTrue ($first.files[0].sha256 -cmatch '^[0-9a-f]{64}$') 'file hash must be lowercase SHA-256'
    }

    Invoke-CcodTest 'runtime IDs use canonical TAB delimiters' {
        $files = @(
            [pscustomobject]@{ path = 'a.txt'; length = [int64]5; sha256 = ('a' * 64) }
            [pscustomobject]@{ path = 'b.txt'; length = [int64]4; sha256 = ('b' * 64) }
        )
        $nonce = '0123456789abcdef0123456789abcdef'
        $expected = '2.5.22-e71f4818a0f8e98f-0123456789abcdef0123456789abcdef'
        Assert-CcodEqual $expected (Get-CcodRuntimeId -ProjectVersion '2.5.22' -Files $files -Nonce $nonce) 'runtime ID digest input must use literal TAB delimiters'
    }

    Invoke-CcodTest 'runtime manifest producer and validator agree on filenames containing consecutive dots' {
        $runtime = Join-Path $root 'consecutive-dots'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'foo..bar'), 'dot filename', [Text.UTF8Encoding]::new($false))
        $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.5.22'
        Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest
        $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $manifest.runtimeId
        Assert-CcodTrue $validation.Valid 'a safe filename with consecutive dots must validate after production'
    }

    Invoke-CcodTest 'runtime manifest rejects control and format characters in relative paths' {
        $module = Get-Module -Name RuntimeManifest
        foreach ($control in @("`t", "`n", "`r", [char]1, [char]0x7f, [char]0x200b)) {
            Assert-CcodThrows { & $module { param($Path) Assert-CcodManifestRelativePath -Path $Path | Out-Null } ('safe' + $control + 'name.txt') } 'CCOD_PATH_OUTSIDE_ROOT'
            $fullName = Join-Path $root ('safe' + $control + 'name.txt')
            Assert-CcodThrows { & $module { param($Root, $FullName) ConvertTo-CcodRuntimeRelativePath -Root $Root -FullName $FullName | Out-Null } $root $fullName } 'CCOD_PATH_OUTSIDE_ROOT'
        }
    }

    Invoke-CcodTest 'verifies exact runtime bytes and rejects tampering' {
        $runtime = Join-Path $root 'verify'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'a.txt'), 'alpha', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $runtime 'b.txt'), 'beta', [Text.UTF8Encoding]::new($false))
        $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0'
        Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest

        Assert-CcodTrue (Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $manifest.runtimeId).Valid 'matching manifest must verify'
        [IO.File]::AppendAllText((Join-Path $runtime 'a.txt'), 'tampered', [Text.UTF8Encoding]::new($false))
        $result = Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $manifest.runtimeId
        Assert-CcodEqual $false $result.Valid 'tampered bytes must be rejected'
    }

    Invoke-CcodTest 'rejects copied renamed and nonce-tampered generation identity' {
        $runtime=Join-Path $root 'identity-original';New-Item -ItemType Directory -Path $runtime|Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'a.txt'),'alpha',[Text.UTF8Encoding]::new($false))
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.5.22'
        Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest
        $originalManifestSha=Get-CcodTestFileSha256 -Path (Join-Path $runtime 'manifest.json')
        $parts=$manifest.runtimeId -split '-';$renamedId=($parts[0..($parts.Count-2)] -join '-')+'-'+('f'*32)
        $renamed=Join-Path $root $renamedId;Copy-Item -LiteralPath $runtime -Destination $renamed -Recurse
        $altered=Get-Content -LiteralPath (Join-Path $renamed 'manifest.json') -Raw|ConvertFrom-Json;$altered.runtimeId=$renamedId
        Write-CcodAtomicJson -Path (Join-Path $renamed 'manifest.json') -Value $altered
        Assert-CcodEqual $false (Test-CcodRuntimeManifest -RuntimeDirectory $renamed -ExpectedRuntimeId $renamedId -ExpectedManifestSha256 $originalManifestSha).Valid 'copied generation cannot authorize a renamed nonce by rewriting its manifest identity'
        $altered.runtimeId=$manifest.runtimeId.Substring(0,$manifest.runtimeId.Length-1)+'A';Write-CcodAtomicJson -Path (Join-Path $renamed 'manifest.json') -Value $altered
        Assert-CcodEqual $false (Test-CcodRuntimeManifest -RuntimeDirectory $renamed -ExpectedRuntimeId $altered.runtimeId).Valid 'wrong non-lowercase nonce is rejected'
    }

    Invoke-CcodTest 'rejects an unsafe manifest path instead of reading outside its runtime' {
        $runtime = Join-Path $root 'unsafe-manifest'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'outside.txt'), 'outside', [Text.UTF8Encoding]::new($false))
        Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value ([ordered]@{
            schemaVersion = 1
            projectVersion = '2.0.0'
            runtimeId = '2.0.0-safe'
            files = @([ordered]@{ path = '../ccod-runtime-outside/outside.txt'; length = 7; sha256 = ('0' * 64) })
        })
        Assert-CcodThrows { Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId '2.0.0-safe' } 'CCOD_PATH_OUTSIDE_ROOT'
    }

    Invoke-CcodTest 'rejects a runtime directory reached through a reparse ancestor' {
        $outsideRuntime = Join-Path $outside 'reparse-runtime'
        $junctionParent = Join-Path $root 'reparse-runtime-parent'
        New-Item -ItemType Directory -Path $outsideRuntime | Out-Null
        [IO.File]::WriteAllText((Join-Path $outsideRuntime 'payload.txt'), 'outside runtime', [Text.UTF8Encoding]::new($false))
        $outsideManifest = New-CcodRuntimeManifest -RuntimeDirectory $outsideRuntime -ProjectVersion '2.0.0'
        Write-CcodAtomicJson -Path (Join-Path $outsideRuntime 'manifest.json') -Value $outsideManifest
        New-Item -ItemType Junction -Path $junctionParent -Target $outside | Out-Null
        $runtime = Join-Path $junctionParent 'reparse-runtime'
        Assert-CcodThrows { New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0' } 'CCOD_REPARSE_PATH'
        Assert-CcodThrows { Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $outsideManifest.runtimeId } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'runtime manifest rejects hardlinked payload files' {
        $runtime = Join-Path $root 'hardlink-payload'
        $outsidePayload = Join-Path $outside 'hardlink-payload.txt'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        [IO.File]::WriteAllText($outsidePayload, 'hardlinked payload', [Text.UTF8Encoding]::new($false))
        New-Item -ItemType HardLink -Path (Join-Path $runtime 'payload.txt') -Target $outsidePayload | Out-Null
        Assert-CcodThrows { New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0' } 'CCOD_RUNTIME_FILE_INVALID'
    }

    Invoke-CcodTest 'runtime manifest rejects a noncanonical runtime directory' {
        $fixture = New-CcodRuntimeFixture -InstallRoot $root -ProjectVersion '2.0.0' -AContent 'a' -BContent 'b'
        $noncanonical = [string]$fixture.Runtime + '\.'
        Assert-CcodThrows { Test-CcodRuntimeManifest -RuntimeDirectory $noncanonical -ExpectedRuntimeId $fixture.Manifest.runtimeId } 'CCOD_RUNTIME_PATH_INVALID'
    }

    Invoke-CcodTest 'runtime manifest rejects a directory at its manifest leaf instead of treating it as missing' {
        $runtime = Join-Path $root 'manifest-leaf-directory'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'payload.txt'), 'payload', [Text.UTF8Encoding]::new($false))
        $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0'
        New-Item -ItemType Directory -Path (Join-Path $runtime 'manifest.json') | Out-Null
        $result = Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $manifest.runtimeId
        Assert-CcodEqual 'CCOD_RUNTIME_MANIFEST_INVALID' $result.Code 'manifest directory is invalid state rather than missing file'
    }

    Invoke-CcodTest 'active pointer rejects a noninteger schema version' {
        $runtime = New-CcodRuntimeFixture -InstallRoot $root -ProjectVersion '2.5.0' -AContent 'a' -BContent 'b'
        $pointer = '{"schemaVersion":2.0,"activeRuntime":"' + $runtime.Manifest.runtimeId + '","previousRuntime":null,"generation":1,"updatedAtUtc":"2030-02-03T04:05:06.0000000Z"}'
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), $pointer, [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $root } 'CCOD_RUNTIME_POINTER_INVALID'
    }

    Invoke-CcodTest 'active pointer rejects a noncanonical UTC timestamp' {
        $runtime = New-CcodRuntimeFixture -InstallRoot $root -ProjectVersion '2.5.0' -AContent 'a' -BContent 'b'
        $pointer = [ordered]@{ schemaVersion = 2; activeRuntime = $runtime.Manifest.runtimeId; previousRuntime = $null; generation = [UInt64]1; updatedAtUtc = 123 }
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), ($pointer | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $root } 'CCOD_RUNTIME_POINTER_INVALID'
    }

    Invoke-CcodTest 'rotates an active pointer only to a verified runtime' {
        $installRoot = Join-Path $root 'install'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $first = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.0' -AContent 'alpha' -BContent 'beta'
        $second = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.1' -AContent 'alpha two' -BContent 'beta two'

        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        $initial = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual 2 $initial.schemaVersion 'new active pointers use schema version two'
        Assert-CcodEqual 1 ([UInt64]$initial.generation) 'first activation starts generation one'
        Assert-CcodEqual $first.Manifest.runtimeId $initial.activeRuntime 'first verified runtime must become active'
        Assert-CcodEqual $null $initial.previousRuntime 'first activation has no previous runtime'

        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId | Out-Null
        $rotated = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual 2 ([UInt64]$rotated.generation) 'every later activation increments generation exactly once'
        Assert-CcodEqual $second.Manifest.runtimeId $rotated.activeRuntime 'new verified runtime must become active'
        Assert-CcodEqual $first.Manifest.runtimeId $rotated.previousRuntime 'old active runtime must become previous'

        [IO.File]::WriteAllText((Join-Path $first.Runtime 'a.txt'), 'gamma', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId } 'CCOD_RUNTIME_FILE_HASH_MISMATCH'
        $unchanged = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual $second.Manifest.runtimeId $unchanged.activeRuntime 'failed activation must leave the active pointer unchanged'
    }

    Invoke-CcodTest 'never sets previousRuntime to the same runtime id on reactivation' {
        $installRoot = Join-Path $root 'same-runtime-reactivation'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $first = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.0' -AContent 'alpha' -BContent 'beta'
        $second = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.1' -AContent 'alpha two' -BContent 'beta two'

        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        $reinstalled = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual $first.Manifest.runtimeId $reinstalled.activeRuntime 'reinstalling the active runtime keeps it active'
        Assert-CcodEqual $null $reinstalled.previousRuntime 'reactivating the same runtime must not self-reference'

        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId | Out-Null
        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId | Out-Null
        $reupgraded = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual $second.Manifest.runtimeId $reupgraded.activeRuntime 'reupgrading keeps the latest runtime active'
        Assert-CcodEqual $first.Manifest.runtimeId $reupgraded.previousRuntime 'previous must retain the distinct older runtime'
    }

    Invoke-CcodTest 'rejects invalid IDs in an active pointer before resolving runtime paths' {
        $installRoot = Join-Path $root 'invalid-pointer'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        Write-CcodAtomicJson -Path (Join-Path $installRoot 'active.json') -Value ([ordered]@{
            schemaVersion = 1
            activeRuntime = '../escape'
            previousRuntime = $null
            updatedAtUtc = '2030-02-03T04:05:06.0000000Z'
        })
        Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $installRoot } 'CCOD_RUNTIME_ID_INVALID'
    }

    Invoke-CcodTest 'rejects dot-only runtime IDs before resolving active runtime paths' {
        foreach ($runtimeId in @('.', '..')) {
            $installRoot = Join-Path $root ('dot-runtime-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $installRoot | Out-Null
            Write-CcodAtomicJson -Path (Join-Path $installRoot 'active.json') -Value ([ordered]@{
                schemaVersion = 1
                activeRuntime = $runtimeId
                previousRuntime = $null
                updatedAtUtc = '2030-02-03T04:05:06.0000000Z'
            })
            Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $installRoot } 'CCOD_RUNTIME_ID_INVALID'
            if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'default immutable pointer fence commits fresh and append-only upgrade with real ownership' {
        $installRoot=Join-Path $root 'default-immutable-fence';[IO.Directory]::CreateDirectory($installRoot)|Out-Null;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess();$firstTx=$null;$secondTx=$null;$ownership=$null
        $makeGeneration={param($Root,$Content,$Nonce)$source=Join-Path $Root ("source-$Nonce.txt");[IO.File]::WriteAllText($source,$Content,[Text.UTF8Encoding]::new($false));$sha=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();$records=@([pscustomobject]@{path='payload.txt';length=[int64](Get-Item $source).Length;sha256=$sha});$id=Get-CcodRuntimeId -ProjectVersion '2.5.22' -Files $records -Nonce $Nonce;$tx=Open-CcodInstallGeneration -InstallRoot $Root -RuntimeId $id;Copy-CcodInstallSealedSource -Generation $tx -SourcePath $source -Leaf 'payload.txt' -ExpectedLength $records[0].length -ExpectedSha256 $sha|Out-Null;$runtime=Join-Path $Root "runtime\$id";$manifest=New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.5.22' -RuntimeId $id;Write-CcodInstallGenerationManifest -Generation $tx -Manifest $manifest|Out-Null;[pscustomobject]@{Id=$id;Transaction=$tx;Generation=$tx}}
        try{
            $first=&$makeGeneration $installRoot 'first' ('1'*32);$firstTx=$first.Transaction
            $owner=[pscustomobject][ordered]@{pid=[int]$process.Id;creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o')}
            $ownership=Enter-CcodLifecycleOwnership -InstallRoot $installRoot -RuntimeId $first.Id -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
            $fresh=Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Id -TargetGeneration $first.Generation -FileTransaction $first.Transaction -Ownership $ownership
            Assert-CcodEqual 1 $fresh.generation 'default fresh fence commits generation one'
            Exit-CcodLifecycleOwnership $ownership|Out-Null;$ownership=$null;Close-CcodInstallFileTransaction $firstTx Ready;$firstTx=$null
            $second=&$makeGeneration $installRoot 'second' ('2'*32);$secondTx=$second.Transaction
            $ownership=Enter-CcodLifecycleOwnership -InstallRoot $installRoot -RuntimeId $fresh.activeRuntime -RuntimeGeneration $fresh.generation -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
            $upgraded=Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Id -TargetGeneration $second.Generation -FileTransaction $second.Transaction -Ownership $ownership
            Assert-CcodEqual 2 $upgraded.generation 'default upgrade fence advances append-only generation';Assert-CcodEqual $second.Id $upgraded.activeRuntime 'default upgrade fence selects the new target'
        }finally{if($null-ne$ownership-and-not$ownership.released){Exit-CcodLifecycleOwnership $ownership|Out-Null};if($null-ne$firstTx){Close-CcodInstallFileTransaction $firstTx Failed};if($null-ne$secondTx){Close-CcodInstallFileTransaction $secondTx Failed};$process.Dispose();$identity.Dispose()}
    }

    Invoke-CcodTest 'append-only active selector rejects unknown reparse ADS and multi-linked leaves' {
        foreach($kind in @('unknown','reparse','ads','multilink')){
            $installRoot=Join-Path $root ("pointer-$kind");$pointerRoot=Join-Path $installRoot 'state\active-generation';$target=Join-Path $outside ("pointer-$kind")
            [IO.Directory]::CreateDirectory($pointerRoot)|Out-Null;[IO.Directory]::CreateDirectory($target)|Out-Null
            $runtimeId='2.5.22-1111111111111111-22222222222222222222222222222222';$path=Join-Path $pointerRoot '00000000000000000001.json';$json='{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'
            if($kind-ceq'unknown'){[IO.File]::WriteAllText((Join-Path $pointerRoot 'unknown.bin'),'x',[Text.UTF8Encoding]::new($false))}
            elseif($kind-ceq'reparse'){New-Item -ItemType Junction -Path $path -Target $target|Out-Null}
            elseif($kind-ceq'ads'){[IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false));Set-Content -LiteralPath $path -Stream 'evidence' -Value 'x' -NoNewline}
            else{$outsideFile=Join-Path $target 'pointer.json';[IO.File]::WriteAllText($outsideFile,$json,[Text.UTF8Encoding]::new($false));New-Item -ItemType HardLink -Path $path -Target $outsideFile|Out-Null}
            Assert-CcodThrows {Read-CcodActiveRuntime -InstallRoot $installRoot|Out-Null} 'CCOD_RUNTIME_POINTER_INVALID'
            if(Test-Path $installRoot){Remove-Item $installRoot -Recurse -Force};if(Test-Path $target){Remove-Item $target -Recurse -Force}
        }
    }

    Invoke-CcodTest 'default immutable fence rejects selector root files and non-not-found lookup failures before pointer commit' {
        foreach($kind in @('root-file','lookup-error')){
            $installRoot=Join-Path $root ("pointer-root-$kind");[IO.Directory]::CreateDirectory($installRoot)|Out-Null;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess();$transaction=$null;$ownership=$null
            try{
                $source=Join-Path $installRoot 'source.txt';[IO.File]::WriteAllText($source,'selector-root-proof',[Text.UTF8Encoding]::new($false));$sha=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();$records=@([pscustomobject]@{path='payload.txt';length=[int64](Get-Item $source).Length;sha256=$sha});$runtimeId=Get-CcodRuntimeId -ProjectVersion '2.5.22' -Files $records -Nonce ('3'*32);$transaction=Open-CcodInstallGeneration -InstallRoot $installRoot -RuntimeId $runtimeId;Copy-CcodInstallSealedSource -Generation $transaction -SourcePath $source -Leaf 'payload.txt' -ExpectedLength $records[0].length -ExpectedSha256 $sha|Out-Null;$runtime=Join-Path $installRoot "runtime\$runtimeId";$manifest=New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.5.22' -RuntimeId $runtimeId;Write-CcodInstallGenerationManifest -Generation $transaction -Manifest $manifest|Out-Null
                $pointerRoot=Join-Path $installRoot 'state\active-generation';if($kind-ceq'root-file'){[IO.Directory]::CreateDirectory((Split-Path $pointerRoot -Parent))|Out-Null;[IO.File]::WriteAllText($pointerRoot,'not-a-directory',[Text.UTF8Encoding]::new($false))}
                $owner=[pscustomobject][ordered]@{pid=[int]$process.Id;creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o')};$ownership=Enter-CcodLifecycleOwnership -InstallRoot $installRoot -RuntimeId $runtimeId -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
                $adapters=if($kind-ceq'lookup-error'){@{GetSelectorRootItem={param($Path)throw [UnauthorizedAccessException]::new('selector lookup denied')}}}else{$null}
                Assert-CcodThrows { Invoke-CcodRuntimeCoreSet -InstallRoot $installRoot -NewRuntimeId $runtimeId -TargetGeneration $transaction -FileTransaction $transaction -Ownership $ownership -Adapters $adapters | Out-Null } 'CCOD_RUNTIME_POINTER_INVALID'
                Assert-CcodEqual $false ([IO.File]::Exists((Join-Path $pointerRoot '00000000000000000001.json'))) "$kind failure publishes no active generation"
            }finally{if($null-ne$ownership-and-not$ownership.released){Exit-CcodLifecycleOwnership $ownership|Out-Null};if($null-ne$transaction){Close-CcodInstallFileTransaction $transaction Failed};$process.Dispose();$identity.Dispose()}
        }
    }

    Invoke-CcodTest 'legacy fallback rejects a state ancestor file before active runtime authorization' {
        $installRoot=Join-Path $root 'pointer-state-file';[IO.Directory]::CreateDirectory($installRoot)|Out-Null
        $runtimeId='2.5.22-1111111111111111-22222222222222222222222222222222'
        $active=[ordered]@{schemaVersion=2;activeRuntime=$runtimeId;previousRuntime=$null;generation=[uint64]1;updatedAtUtc='2030-02-03T04:05:06.0000000Z'}
        [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'),($active|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $installRoot 'state'),'not-a-directory',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Read-CcodActiveRuntime -InstallRoot $installRoot|Out-Null} 'CCOD_RUNTIME_POINTER_INVALID'
    }

    Invoke-CcodTest 'includes the lifecycle worker and coordinator in the staged runtime closure' {
        $sourceFiles=@(& $installLifecycleModule {param($sourceRoot)Get-CcodLifecycleSourceFiles -SourceRoot $sourceRoot} $repositoryRoot)
        foreach($relative in @('src\persistence\LifecycleWorker.ps1','src\persistence\SessionController.ps1','src\persistence\modules\LifecycleCoordinator.psm1','src\persistence\modules\LifecycleEpoch.psm1','src\persistence\modules\ProcessControl.psm1','src\persistence\modules\SessionEngine.psm1','src\persistence\modules\WorkerRuntime.psm1')){
            $matches=@($sourceFiles|Where-Object{$_.Relative -ceq $relative})
            Assert-CcodEqual 1 $matches.Count "$relative is staged exactly once"
            Assert-CcodTrue ([IO.File]::Exists($matches[0].Source)) "$relative resolves to a regular source file"
        }
    }

    Invoke-CcodTest 'resolves only the exact active manifest worker and generation' {
        $installRoot=Join-Path $root 'worker-context';New-Item -ItemType Directory -Path $installRoot|Out-Null
        $staging=Join-Path $installRoot 'staging';New-Item -ItemType Directory -Path (Join-Path $staging 'src\persistence') -Force|Out-Null
        $worker=Join-Path $staging 'src\persistence\LifecycleWorker.ps1'
        [IO.File]::WriteAllText($worker,"# lifecycle worker`r`n",[Text.UTF8Encoding]::new($false))
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion '2.5.0'
        $runtime=Join-Path (Join-Path $installRoot 'runtime') $manifest.runtimeId;[IO.Directory]::CreateDirectory((Split-Path $runtime -Parent))|Out-Null
        [IO.Directory]::Move($staging,$runtime);Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest
        Write-CcodAtomicJson -Path (Join-Path $installRoot 'active.json') -Value ([ordered]@{schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[UInt64]4;updatedAtUtc='2030-02-03T04:05:06.0000000Z'})
        $installedWorker=[IO.Path]::GetFullPath((Join-Path $runtime 'src\persistence\LifecycleWorker.ps1'))
        $context=Resolve-CcodActiveRuntimeContext -InstallRoot ([IO.Path]::GetFullPath($installRoot)) -ExpectedRuntimeId $manifest.runtimeId -ExpectedGeneration 4 -ExpectedScriptPath $installedWorker -ScriptRelativePath 'src/persistence/LifecycleWorker.ps1'
        Assert-CcodEqual 'InstallRoot,RuntimeRoot,RuntimeId,RuntimeGeneration,ScriptPath,Manifest' (($context.PSObject.Properties.Name)-join ',') 'active worker context exact shape'
        Assert-CcodEqual 4 ([UInt64]$context.RuntimeGeneration) 'active generation is retained'
        Assert-CcodThrows { Resolve-CcodActiveRuntimeContext -InstallRoot ([IO.Path]::GetFullPath($installRoot)) -ExpectedRuntimeId $manifest.runtimeId -ExpectedGeneration 5 -ExpectedScriptPath $installedWorker -ScriptRelativePath 'src/persistence/LifecycleWorker.ps1' } 'CCOD_RUNTIME_UNAUTHORIZED'
        Assert-CcodThrows { Resolve-CcodActiveRuntimeContext -InstallRoot ([IO.Path]::GetFullPath($installRoot)) -ExpectedRuntimeId $manifest.runtimeId -ExpectedGeneration 4 -ExpectedScriptPath (Join-Path $runtime 'src\persistence\SessionController.ps1') -ScriptRelativePath 'src/persistence/LifecycleWorker.ps1' } 'CCOD_RUNTIME_UNAUTHORIZED'
    }

    Invoke-CcodTest 'maps a legacy schema-one pointer to generation one before the next schema-two commit' {
        $installRoot = Join-Path $root 'schema-one-migration'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $first = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.1' -AContent 'legacy alpha' -BContent 'legacy beta'
        $second = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.2' -AContent 'next alpha' -BContent 'next beta'
        Write-CcodAtomicJson -Path (Join-Path $installRoot 'active.json') -Value ([ordered]@{
            schemaVersion = 1; activeRuntime = $first.Manifest.runtimeId; previousRuntime = $null; updatedAtUtc = '2030-02-03T04:05:06.0000000Z'
        })

        $legacy = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual 2 $legacy.schemaVersion 'legacy read exposes the fenced pointer shape'
        Assert-CcodEqual 1 ([UInt64]$legacy.generation) 'legacy pointer deterministically maps to generation one'
        $committed = Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId
        Assert-CcodEqual 2 $committed.schemaVersion 'migration commit never downgrades the pointer schema'
        Assert-CcodEqual 2 ([UInt64]$committed.generation) 'the next commit advances from migrated generation one'
    }

    Invoke-CcodTest 'writes an exact injected UTC timestamp when activating a verified runtime' {
        $installRoot = Join-Path $root 'fixed-clock'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $runtime = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.0' -AContent 'clock alpha' -BContent 'clock beta'
        $fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06.0000000Z').ToUniversalTime()

        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $runtime.Manifest.runtimeId -Adapters @{ UtcNow = { $fixedUtc } } | Out-Null
        Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' (Read-CcodActiveRuntime -InstallRoot $installRoot).updatedAtUtc 'active pointer must use the injected UTC clock exactly'
    }

    Invoke-CcodTest 'rejects an active runtime mutation that has no proven lifecycle ownership' {
        $installRoot = Join-Path $root 'unfenced-mutation'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $runtime = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.3' -AContent 'fence alpha' -BContent 'fence beta'
        Assert-CcodThrows { Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $runtime.Manifest.runtimeId } 'CCOD_RUNTIME_FENCE_REQUIRED'
        Assert-CcodEqual $false ([IO.File]::Exists((Join-Path $installRoot 'active.json'))) 'unfenced mutation writes no active pointer'
    }

    Invoke-CcodTest 'rejects initial active pointer creation after lifecycle ownership is released' {
        $installRoot = Join-Path $root 'released-initial-owner'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $runtime = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.4' -AContent 'released alpha' -BContent 'released beta'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $owner = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
            $ownership = Enter-CcodLifecycleOwnership -InstallRoot $installRoot -RuntimeId $runtime.Manifest.runtimeId -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
            Exit-CcodLifecycleOwnership -Ownership $ownership | Out-Null
            Assert-CcodThrows { Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $runtime.Manifest.runtimeId -Ownership $ownership } 'CCOD_RUNTIME_FENCE_STALE'
            Assert-CcodEqual $false ([IO.File]::Exists((Join-Path $installRoot 'active.json'))) 'released initial owner writes no active pointer'
        } finally { $process.Dispose(); $identity.Dispose() }
    }

    Invoke-CcodTest 'rejects initial active pointer creation from a noninitial runtime generation' {
        $installRoot = Join-Path $root 'wrong-initial-generation'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $runtime = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.5' -AContent 'generation alpha' -BContent 'generation beta'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $process = [Diagnostics.Process]::GetCurrentProcess()
        $ownership = $null
        try {
            $owner = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
            $ownership = Enter-CcodLifecycleOwnership -InstallRoot $installRoot -RuntimeId $runtime.Manifest.runtimeId -RuntimeGeneration 2 -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
            Assert-CcodThrows { Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $runtime.Manifest.runtimeId -Ownership $ownership } 'CCOD_RUNTIME_FENCE_STALE'
            Assert-CcodEqual $false ([IO.File]::Exists((Join-Path $installRoot 'active.json'))) 'noninitial generation writes no initial active pointer'
        } finally {
            if ($null -ne $ownership -and -not $ownership.released) { Exit-CcodLifecycleOwnership -Ownership $ownership | Out-Null }
            $process.Dispose(); $identity.Dispose()
        }
    }

    Invoke-CcodTest 'rejects a generation change between the protected pointer read and commit' {
        $installRoot = Join-Path $root 'generation-race'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $first = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.2.0' -AContent 'first alpha' -BContent 'first beta'
        $second = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.2.1' -AContent 'second alpha' -BContent 'second beta'
        Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $process = [Diagnostics.Process]::GetCurrentProcess()
        $ownership = $null
        try {
            $current = Read-CcodActiveRuntime -InstallRoot $installRoot
            $owner = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
            $ownership = Enter-CcodLifecycleOwnership -InstallRoot $installRoot -RuntimeId $current.activeRuntime -RuntimeGeneration $current.generation -OwnerIdentity $owner -UserSid $identity.User.Value -SessionId ([int]$process.SessionId)
            $assertions = 0
            $raceFence = {
                param($Root, $Receipt, $ExpectActivePointer)
                $assertions++
                [void](Assert-CcodLifecycleFence -InstallRoot $Root -Ownership $Receipt)
                if ($assertions -eq 1) {
                    Write-CcodAtomicJson -Path (Join-Path $Root 'active.json') -Value ([ordered]@{
                        schemaVersion=2; activeRuntime=$Receipt.runtimeId; previousRuntime=$null
                        generation=[UInt64]($Receipt.runtimeGeneration + 1); updatedAtUtc='2030-02-03T04:05:06.0000000Z'
                    })
                }
                return $true
            }.GetNewClosure()
            Assert-CcodThrows { Invoke-CcodRuntimeCoreSet -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId -Ownership $ownership -Adapters @{ AssertLifecycleFence=$raceFence } } 'CCOD_RUNTIME_FENCE_STALE'
            $unchanged = Read-CcodActiveRuntime -InstallRoot $installRoot
            Assert-CcodEqual 2 ([UInt64]$unchanged.generation) 'concurrent generation remains committed instead of being reused'
            Assert-CcodEqual $first.Manifest.runtimeId $unchanged.activeRuntime 'stale owner cannot replace the concurrent active runtime'
        } finally {
            if ($null -ne $ownership -and -not $ownership.released) { Exit-CcodLifecycleOwnership -Ownership $ownership | Out-Null }
            $process.Dispose(); $identity.Dispose()
        }
    }

    Invoke-CcodTest 'preserves an integral Decimal UInt64 generation and rejects a fractional generation' {
        $installRoot = Join-Path $root 'decimal-generation'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $pointer = [ordered]@{ schemaVersion=2; activeRuntime='2.5.0-a'; previousRuntime=$null; generation=[UInt64]::MaxValue; updatedAtUtc='2030-02-03T04:05:06.0000000Z' }
        [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'), ($pointer | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Assert-CcodEqual ([UInt64]::MaxValue) ([UInt64](Read-CcodActiveRuntime -InstallRoot $installRoot).generation) 'PowerShell Decimal representation preserves UInt64 maximum'
        $next = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.5.1' -AContent 'next alpha' -BContent 'next beta'
        Assert-CcodThrows { Set-CcodTestActiveRuntime -InstallRoot $installRoot -NewRuntimeId $next.Manifest.runtimeId } 'CCOD_RUNTIME_GENERATION_EXHAUSTED'
        [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'), '{"schemaVersion":2,"activeRuntime":"2.5.0-a","previousRuntime":null,"generation":1.5,"updatedAtUtc":"2030-02-03T04:05:06.0000000Z"}', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $installRoot } 'CCOD_RUNTIME_GENERATION_INVALID'
        [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'), '{"schemaVersion":2,"activeRuntime":"2.5.0-a","previousRuntime":null,"generation":18446744073709551616,"updatedAtUtc":"2030-02-03T04:05:06.0000000Z"}', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $installRoot } 'CCOD_RUNTIME_GENERATION_INVALID'
    }

    Invoke-CcodTest 'accepts Decimal previousGeneration values in active-generation records' {
        $installRoot = Join-Path $root 'decimal-previous-generation'
        $pointerRoot = Join-Path $installRoot 'state\active-generation'
        New-Item -ItemType Directory -Path $pointerRoot -Force | Out-Null
        $record = [ordered]@{ schemaVersion = 1; generation = [decimal]2; activeRuntime = '2.5.22-a'; previousGeneration = [decimal]1 }
        [IO.File]::WriteAllText((Join-Path $pointerRoot '00000000000000000002.json'), ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $first = [ordered]@{ schemaVersion = 1; generation = 1; activeRuntime = '2.5.22-b'; previousGeneration = 0 }
        [IO.File]::WriteAllText((Join-Path $pointerRoot '00000000000000000001.json'), ($first | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $actual = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodTrue ([UInt64]$actual.generation -eq [UInt64]2) 'Decimal previousGeneration must not invalidate an otherwise canonical selector chain'
    }

    Invoke-CcodTest 'rejects legacy active pointer files with alternate data streams' {
        $installRoot = Join-Path $root 'legacy-pointer-stream'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $runtime = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.3.0' -AContent 'ads alpha' -BContent 'ads beta'
        Write-CcodAtomicJson -Path (Join-Path $installRoot 'active.json') -Value ([ordered]@{ schemaVersion = 1; activeRuntime = $runtime.Manifest.runtimeId; previousRuntime = $null; updatedAtUtc = '2030-02-03T04:05:06.0000000Z' })
        Add-Content -LiteralPath (Join-Path $installRoot 'active.json') -Stream 'unexpected' -Value 'tampered'
        Assert-CcodThrows { Read-CcodActiveRuntime -InstallRoot $installRoot } 'CCOD_RUNTIME_POINTER_INVALID'
    }

    Invoke-CcodTest 'runtime manifest rejects scalar files and noninteger lengths' {
        $installRoot = Join-Path $root 'manifest-strict-shape'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $fixture = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.3.1' -AContent 'shape alpha' -BContent 'shape beta'
        $path = Join-Path $fixture.Runtime 'manifest.json'
        $valid = $fixture.Manifest
        $scalar = [ordered]@{ schemaVersion = 1; projectVersion = '2.3.1'; runtimeId = $valid.runtimeId; files = [ordered]@{ path = 'a.txt'; length = 1; sha256 = ('0' * 64) } }
        Write-CcodAtomicJson -Path $path -Value $scalar
        Assert-CcodEqual 'CCOD_RUNTIME_MANIFEST_INVALID' (Test-CcodRuntimeManifest -RuntimeDirectory $fixture.Runtime -ExpectedRuntimeId $valid.runtimeId).Code 'scalar files are rejected by shape'
        $fraction = [ordered]@{ schemaVersion = 1; projectVersion = '2.3.1'; runtimeId = $valid.runtimeId; files = @([ordered]@{ path = 'a.txt'; length = 1.5; sha256 = ('0' * 64) }) }
        Write-CcodAtomicJson -Path $path -Value $fraction
        Assert-CcodEqual 'CCOD_RUNTIME_MANIFEST_INVALID' (Test-CcodRuntimeManifest -RuntimeDirectory $fixture.Runtime -ExpectedRuntimeId $valid.runtimeId).Code 'fractional lengths are rejected by shape'
    }

    Invoke-CcodTest 'runtime manifest rejects extra properties and string schema versions' {
        $installRoot = Join-Path $root 'manifest-strict-extra'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $fixture = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.3.2' -AContent 'extra alpha' -BContent 'extra beta'
        $path = Join-Path $fixture.Runtime 'manifest.json'
        $valid = $fixture.Manifest
        $extra = [ordered]@{ schemaVersion = 1; projectVersion = '2.3.2'; runtimeId = $valid.runtimeId; files = @(); unexpected = 'x' }
        Write-CcodAtomicJson -Path $path -Value $extra
        Assert-CcodEqual 'CCOD_RUNTIME_MANIFEST_INVALID' (Test-CcodRuntimeManifest -RuntimeDirectory $fixture.Runtime -ExpectedRuntimeId $valid.runtimeId).Code 'extra manifest fields are rejected'
        $stringSchema = [ordered]@{ schemaVersion = '1'; projectVersion = '2.3.2'; runtimeId = $valid.runtimeId; files = @() }
        Write-CcodAtomicJson -Path $path -Value $stringSchema
        Assert-CcodEqual 'CCOD_RUNTIME_MANIFEST_INVALID' (Test-CcodRuntimeManifest -RuntimeDirectory $fixture.Runtime -ExpectedRuntimeId $valid.runtimeId).Code 'string schema version is rejected'
    }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
}
