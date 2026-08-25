$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\PortableRelease.psm1'
Import-Module $modulePath -Force

function Get-CcodPortableReleaseTestHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-CcodPortableReleaseFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-portable-release-' + [guid]::NewGuid().ToString('N'))
    $payload = Join-Path $root 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    $file = Join-Path $payload 'safe.txt'
    [IO.File]::WriteAllText($file,'portable fixture',[Text.UTF8Encoding]::new($false))
    $manifestPath = Join-Path $root 'payload-manifest.json'
    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'CodexRemote-fix'
        version = '2.5.6'
        gitCommit = ('a' * 40)
        buildTimestampUtc = '2026-08-25T00:00:00.0000000Z'
        files = @([ordered]@{path='safe.txt';length=[int64](Get-Item -LiteralPath $file).Length;sha256=Get-CcodPortableReleaseTestHash -Path $file})
    }
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$root;Payload=$payload;Manifest=$manifestPath;File=$file}
}

Invoke-CcodTest 'portable payload manifest validates an exact file record set' {
    $fixture = New-CcodPortableReleaseFixture
    try {
        $result = Test-CcodPortablePayloadManifest -PayloadRoot $fixture.Payload -ManifestPath $fixture.Manifest -ExpectedVersion '2.5.6' -ExpectedGitCommit ('a' * 40)
        Assert-CcodEqual $true ([bool]$result.Valid) 'valid portable payload manifest passes'
        Assert-CcodEqual 1 @($result.Files).Count 'valid portable payload manifest returns its exact file set'
        Assert-CcodTrue ($result.PayloadManifestSha256 -cmatch '^[0-9a-f]{64}$') 'payload manifest receipt binds a canonical SHA-256'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'portable payload manifest rejects altered bytes and ambiguous JSON' {
    $fixture = New-CcodPortableReleaseFixture
    try {
        [IO.File]::WriteAllText($fixture.File,'tampered',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Test-CcodPortablePayloadManifest -PayloadRoot $fixture.Payload -ManifestPath $fixture.Manifest | Out-Null
        } 'CCOD_PORTABLE_MANIFEST_INVALID'
        [IO.File]::WriteAllText($fixture.File,'portable fixture',[Text.UTF8Encoding]::new($false))
        $manifest = Get-Content -LiteralPath $fixture.Manifest -Raw
        $ambiguous = $manifest.Replace('"files":','"files":[],"files":')
        [IO.File]::WriteAllText($fixture.Manifest,$ambiguous,[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Test-CcodPortablePayloadManifest -PayloadRoot $fixture.Payload -ManifestPath $fixture.Manifest | Out-Null
        } 'CCOD_PORTABLE_MANIFEST_INVALID'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'portable payload manifest rejects executable alternate streams but permits download provenance' {
    $fixture = New-CcodPortableReleaseFixture
    try {
        Set-Content -LiteralPath $fixture.File -Stream 'CcodUnexpected' -Value 'unexpected stream' -NoNewline
        Assert-CcodThrows {
            Test-CcodPortablePayloadManifest -PayloadRoot $fixture.Payload -ManifestPath $fixture.Manifest | Out-Null
        } 'CCOD_PORTABLE_ADS_INVALID'
        Remove-Item -LiteralPath $fixture.File -Stream 'CcodUnexpected' -Force
        Set-Content -LiteralPath $fixture.File -Stream 'Zone.Identifier' -Value '[ZoneTransfer]' -NoNewline
        $result = Test-CcodPortablePayloadManifest -PayloadRoot $fixture.Payload -ManifestPath $fixture.Manifest
        Assert-CcodEqual $true ([bool]$result.Valid) 'download provenance stream does not bypass the manifest gate'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'portable payload copy refuses arbitrary caller-selected installation roots' {
    $fixture = New-CcodPortableReleaseFixture
    try {
        Assert-CcodThrows {
            Copy-CcodPortablePayload -PayloadRoot $fixture.Payload -ManifestPath $fixture.Manifest -InstallerRoot (Join-Path $fixture.Root 'arbitrary-root') | Out-Null
        } 'CCOD_PORTABLE_PATH_INVALID'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Write-Host 'Portable release self-tests passed.'
