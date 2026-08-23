$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
$installLifecycleModule = Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\InstallLifecycle.psm1') -PassThru
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force

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

try {
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

        Assert-CcodTrue ($first.runtimeId -match '^[A-Za-z0-9._-]{1,96}$') 'runtime ID must be a safe name'
        Assert-CcodEqual $first.runtimeId $second.runtimeId 'the same runtime bytes must produce the same runtime ID'
        Assert-CcodEqual 'a.txt' $first.files[0].path 'files must sort ordinally'
        Assert-CcodEqual 'b.txt' $first.files[1].path 'files must sort ordinally'
        Assert-CcodEqual 2 $first.files.Count 'manifest must exclude manifest.json itself'
        Assert-CcodTrue ($first.files[0].sha256 -cmatch '^[0-9a-f]{64}$') 'file hash must be lowercase SHA-256'
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

    Invoke-CcodTest 'rotates an active pointer only to a verified runtime' {
        $installRoot = Join-Path $root 'install'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $first = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.0' -AContent 'alpha' -BContent 'beta'
        $second = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.1' -AContent 'alpha two' -BContent 'beta two'

        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        $initial = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual 2 $initial.schemaVersion 'new active pointers use schema version two'
        Assert-CcodEqual 1 ([UInt64]$initial.generation) 'first activation starts generation one'
        Assert-CcodEqual $first.Manifest.runtimeId $initial.activeRuntime 'first verified runtime must become active'
        Assert-CcodEqual $null $initial.previousRuntime 'first activation has no previous runtime'

        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId | Out-Null
        $rotated = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual 2 ([UInt64]$rotated.generation) 'every later activation increments generation exactly once'
        Assert-CcodEqual $second.Manifest.runtimeId $rotated.activeRuntime 'new verified runtime must become active'
        Assert-CcodEqual $first.Manifest.runtimeId $rotated.previousRuntime 'old active runtime must become previous'

        [IO.File]::WriteAllText((Join-Path $first.Runtime 'a.txt'), 'gamma', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId } 'CCOD_RUNTIME_FILE_HASH_MISMATCH'
        $unchanged = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual $second.Manifest.runtimeId $unchanged.activeRuntime 'failed activation must leave the active pointer unchanged'
    }

    Invoke-CcodTest 'never sets previousRuntime to the same runtime id on reactivation' {
        $installRoot = Join-Path $root 'same-runtime-reactivation'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $first = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.0' -AContent 'alpha' -BContent 'beta'
        $second = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.0.1' -AContent 'alpha two' -BContent 'beta two'

        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $first.Manifest.runtimeId | Out-Null
        $reinstalled = Read-CcodActiveRuntime -InstallRoot $installRoot
        Assert-CcodEqual $first.Manifest.runtimeId $reinstalled.activeRuntime 'reinstalling the active runtime keeps it active'
        Assert-CcodEqual $null $reinstalled.previousRuntime 'reactivating the same runtime must not self-reference'

        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId | Out-Null
        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId | Out-Null
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
        $committed = Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $second.Manifest.runtimeId
        Assert-CcodEqual 2 $committed.schemaVersion 'migration commit never downgrades the pointer schema'
        Assert-CcodEqual 2 ([UInt64]$committed.generation) 'the next commit advances from migrated generation one'
    }

    Invoke-CcodTest 'writes an exact injected UTC timestamp when activating a verified runtime' {
        $installRoot = Join-Path $root 'fixed-clock'
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        $runtime = New-CcodRuntimeFixture -InstallRoot $installRoot -ProjectVersion '2.1.0' -AContent 'clock alpha' -BContent 'clock beta'
        $fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06.0000000Z').ToUniversalTime()

        Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $runtime.Manifest.runtimeId -Adapters @{ UtcNow = { $fixedUtc } } | Out-Null
        Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' (Read-CcodActiveRuntime -InstallRoot $installRoot).updatedAtUtc 'active pointer must use the injected UTC clock exactly'
    }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
}
