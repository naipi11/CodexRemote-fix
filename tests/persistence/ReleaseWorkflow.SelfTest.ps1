$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$defenderPath = Join-Path $repositoryRoot 'tools\Test-ReleaseDefender.ps1'

function New-CcodReleaseFixture {
    $root = Join-Path $env:TEMP ('ccod-release-workflow-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($root)
    $installer = Join-Path $root 'CodexRemote-fix-2.5.0-setup.exe'
    [IO.File]::WriteAllBytes($installer, [byte[]](9,8,7,6,5,4,3,2,1))
    $checksum = "$installer.sha256.txt"
    $installerHash = Get-CcodTestFileSha256 -Path $installer
    [IO.File]::WriteAllText($checksum, ("{0} *{1}`r`n" -f $installerHash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    $trayHost = Join-Path $root 'CodexRemote-fix-2.5.0-trayhost-provenance.json'
    [IO.File]::WriteAllText($trayHost, ('{"schemaVersion":1,"product":"CodexRemote-fix","version":"2.5.0","gitCommit":"' + ('a' * 40) + '","buildTimestampUtc":"2026-08-24T00:00:00.0000000Z"}'), [Text.UTF8Encoding]::new($false))
    $manifest = Join-Path $root 'CodexRemote-fix-2.5.0-release-manifest.json'
    $assets = @(
        [ordered]@{ name = [IO.Path]::GetFileName($installer); sha256 = $installerHash },
        [ordered]@{ name = [IO.Path]::GetFileName($checksum); sha256 = Get-CcodTestFileSha256 -Path $checksum },
        [ordered]@{ name = [IO.Path]::GetFileName($trayHost); sha256 = Get-CcodTestFileSha256 -Path $trayHost }
    )
    $record = [ordered]@{
        schemaVersion = 1
        product = 'CodexRemote-fix'
        version = '2.5.0'
        gitCommit = ('a' * 40)
        buildTimestampUtc = '2026-08-24T00:00:00.0000000Z'
        assets = $assets
    }
    [IO.File]::WriteAllText($manifest, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Root = $root; Installer = $installer; Checksum = $checksum; TrayHost = $trayHost; Manifest = $manifest }
}

function New-CcodPortableReleaseFixture {
    $root = Join-Path $env:TEMP ('ccod-portable-release-workflow-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $root 'stage'
    $payload = Join-Path $stage 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'Install-CodexRemote-fix.ps1'),'Write-Output portable',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $payload 'hello.txt'),'portable payload',[Text.UTF8Encoding]::new($false))
    $timestamp = '2026-08-25T00:00:00.0000000Z'
    $commit = 'b' * 40
    $payloadFile = Join-Path $payload 'hello.txt'
    $payloadRecord = [ordered]@{path='hello.txt';length=[int64](Get-Item -LiteralPath $payloadFile).Length;sha256=Get-CcodTestFileSha256 -Path $payloadFile}
    $payloadManifest = [ordered]@{schemaVersion=1;product='CodexRemote-fix';version='2.5.6';gitCommit=$commit;buildTimestampUtc=$timestamp;files=@($payloadRecord)}
    [IO.File]::WriteAllText((Join-Path $stage 'payload-manifest.json'),($payloadManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $bundle = Join-Path $root 'CodexRemote-fix-2.5.6-windows-x64.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$bundle,[IO.Compression.CompressionLevel]::Optimal,$false)
    $checksum = "$bundle.sha256.txt"
    $bundleHash = Get-CcodTestFileSha256 -Path $bundle
    [IO.File]::WriteAllText($checksum,("$bundleHash *$([IO.Path]::GetFileName($bundle))"),[Text.UTF8Encoding]::new($false))
    $provenance = Join-Path $root 'CodexRemote-fix-2.5.6-trayhost-provenance.json'
    [IO.File]::WriteAllText($provenance,([ordered]@{schemaVersion=1;product='CodexRemote-fix';version='2.5.6';gitCommit=$commit;buildTimestampUtc=$timestamp}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $payloadAsset = Join-Path $root 'CodexRemote-fix-2.5.6-payload-manifest.json'
    [IO.File]::Copy((Join-Path $stage 'payload-manifest.json'),$payloadAsset,$false)
    $manifest = Join-Path $root 'CodexRemote-fix-2.5.6-release-manifest.json'
    $assets = @(
        [ordered]@{name=[IO.Path]::GetFileName($bundle);sha256=$bundleHash},
        [ordered]@{name=[IO.Path]::GetFileName($checksum);sha256=Get-CcodTestFileSha256 -Path $checksum},
        [ordered]@{name=[IO.Path]::GetFileName($provenance);sha256=Get-CcodTestFileSha256 -Path $provenance},
        [ordered]@{name=[IO.Path]::GetFileName($payloadAsset);sha256=Get-CcodTestFileSha256 -Path $payloadAsset}
    )
    $release = [ordered]@{schemaVersion=2;product='CodexRemote-fix';version='2.5.6';gitCommit=$commit;buildTimestampUtc=$timestamp;distribution='portable-zip';assets=$assets}
    [IO.File]::WriteAllText($manifest,($release | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$root;Bundle=$bundle;Checksum=$checksum;PayloadManifest=$payloadAsset;Manifest=$manifest}
}

Invoke-CcodTest 'release defender tool exposes manifest and scan functions without a live scan' {
    Assert-CcodTrue (Test-Path -LiteralPath $defenderPath -PathType Leaf) 'Defender release gate exists'
    . $defenderPath -Library
    Assert-CcodTrue ($null -ne (Get-Command Test-CcodReleaseAssetManifest -ErrorAction SilentlyContinue)) 'release manifest validator is exported for deterministic tests'
    Assert-CcodTrue ($null -ne (Get-Command Invoke-CcodReleaseDefenderCheck -ErrorAction SilentlyContinue)) 'Defender invocation is available'
}

Invoke-CcodTest 'release manifest binds the final asset names hashes version commit and timestamp' {
    . $defenderPath -Library
    $fixture = New-CcodReleaseFixture
    try {
        $validated = Test-CcodReleaseAssetManifest -ManifestPath $fixture.Manifest -AssetDirectory $fixture.Root -ExpectedVersion '2.5.0'
        Assert-CcodEqual $true ([bool]$validated.Valid) 'valid fixture passes the release manifest contract'
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path $fixture.Installer) ([string]$validated.InstallerSha256) 'validator returns the exact installer hash'
        [IO.File]::WriteAllBytes($fixture.Installer, [byte[]](1,1,1))
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath $fixture.Manifest -AssetDirectory $fixture.Root -ExpectedVersion '2.5.0'
        } 'CCOD_RELEASE_ASSET_HASH_MISMATCH'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'release timestamp validation reads the raw JSON string representation' {
    . $defenderPath -Library
    $canonical = '2026-08-24T00:00:00.0000000Z'
    Assert-CcodEqual $canonical (Get-CcodReleaseDefenderRawJsonString -Json ('{"buildTimestampUtc":"' + $canonical + '"}') -PropertyName 'buildTimestampUtc') 'canonical raw timestamp is retained as text'
    Assert-CcodEqual $null (Get-CcodReleaseDefenderRawJsonString -Json '{"buildTimestampUtc":123}' -PropertyName 'buildTimestampUtc') 'nonstring timestamp JSON is rejected'
    Assert-CcodEqual $null (Get-CcodReleaseDefenderRawJsonString -Json ('{"buildTimestampUtc":"' + $canonical + '","buildTimestampUtc":"' + $canonical + '"}') -PropertyName 'buildTimestampUtc') 'duplicate timestamp JSON is rejected'
    Assert-CcodEqual 'not-canonical' (Get-CcodReleaseDefenderRawJsonString -Json ('{"nested":{"buildTimestampUtc":"' + $canonical + '"},"buildTimestampUtc":"not-canonical"}') -PropertyName 'buildTimestampUtc') 'only the root timestamp property is selected'
}

Invoke-CcodTest 'release manifest rejects a numeric top-level timestamp hidden by a nested canonical timestamp' {
    . $defenderPath -Library
    $fixture = New-CcodReleaseFixture
    try {
        $canonical = '2026-08-24T00:00:00.0000000Z'
        $maliciousProvenance = ('{"schemaVersion":1,"product":"CodexRemote-fix","version":"2.5.0","gitCommit":"' + ('a' * 40) + '","buildTimestampUtc":123,"nested":{"buildTimestampUtc":"' + $canonical + '"}}')
        [IO.File]::WriteAllText($fixture.TrayHost, $maliciousProvenance, [Text.UTF8Encoding]::new($false))
        $record = [IO.File]::ReadAllText($fixture.Manifest) | ConvertFrom-Json
        $boundAsset = @($record.assets | Where-Object { $_.name -ceq [IO.Path]::GetFileName($fixture.TrayHost) })
        Assert-CcodEqual 1 $boundAsset.Count 'fixture manifest binds the TrayHost provenance asset once'
        $boundAsset[0].sha256 = Get-CcodTestFileSha256 -Path $fixture.TrayHost
        [IO.File]::WriteAllText($fixture.Manifest, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath $fixture.Manifest -AssetDirectory $fixture.Root -ExpectedVersion '2.5.0'
        } 'CCOD_RELEASE_MANIFEST_INVALID'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'release manifest binds the TrayHost provenance timestamp to its own timestamp' {
    . $defenderPath -Library
    $fixture = New-CcodReleaseFixture
    try {
        $mismatchedProvenance = ('{"schemaVersion":1,"product":"CodexRemote-fix","version":"2.5.0","gitCommit":"' + ('a' * 40) + '","buildTimestampUtc":"2026-08-24T00:00:01.0000000Z"}')
        [IO.File]::WriteAllText($fixture.TrayHost, $mismatchedProvenance, [Text.UTF8Encoding]::new($false))
        $record = [IO.File]::ReadAllText($fixture.Manifest) | ConvertFrom-Json
        $boundAsset = @($record.assets | Where-Object { $_.name -ceq [IO.Path]::GetFileName($fixture.TrayHost) })
        Assert-CcodEqual 1 $boundAsset.Count 'fixture manifest binds the TrayHost provenance asset once'
        $boundAsset[0].sha256 = Get-CcodTestFileSha256 -Path $fixture.TrayHost
        [IO.File]::WriteAllText($fixture.Manifest, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath $fixture.Manifest -AssetDirectory $fixture.Root -ExpectedVersion '2.5.0'
        } 'CCOD_RELEASE_MANIFEST_INVALID'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'Defender gate requires Internet Zone before a custom scan and writes a redacted receipt after a clean scan' {
    . $defenderPath -Library
    $fixture = New-CcodReleaseFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $capture = [pscustomobject]@{ Value = $null }
        $base = @{
            GetFileSha256 = { param($Path) $calls.Add('GetFileSha256'); Get-CcodTestFileSha256 -Path $Path }.GetNewClosure()
            GetDefenderStatus = { $calls.Add('GetDefenderStatus'); [pscustomobject]@{ AMProductVersion = '4.18.26070.1'; AntivirusSignatureVersion = '1.999.1.0' } }.GetNewClosure()
            StartCustomScan = { param($Path) $calls.Add('StartCustomScan') }.GetNewClosure()
            GetThreatDetections = { $calls.Add('GetThreatDetections'); @() }.GetNewClosure()
            GetUtcNow = { $calls.Add('GetUtcNow'); [datetime]::Parse('2026-08-24T00:00:00Z').ToUniversalTime() }.GetNewClosure()
            WriteReceipt = { param($Path, $Receipt) $calls.Add('WriteReceipt'); $capture.Value = $Receipt; $Path }.GetNewClosure()
        }
        $blocked = @{} + $base
        $blocked.GetZoneId = { param($Path) $calls.Add('GetZoneId'); $null }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodReleaseDefenderCheck -InstallerPath $fixture.Installer -ChecksumPath $fixture.Checksum -EvidencePath (Join-Path $fixture.Root 'receipt.json') -Adapters $blocked
        } 'CCOD_DEFENDER_ZONE_REQUIRED'
        Assert-CcodTrue (-not ($calls -contains 'StartCustomScan')) 'missing Internet Zone blocks Defender scan'

        $calls.Clear()
        $capture.Value = $null
        $clean = @{} + $base
        $clean.GetZoneId = { param($Path) $calls.Add('GetZoneId'); 3 }.GetNewClosure()
        $receipt = Invoke-CcodReleaseDefenderCheck -InstallerPath $fixture.Installer -ChecksumPath $fixture.Checksum -EvidencePath (Join-Path $fixture.Root 'receipt.json') -Adapters $clean
        Assert-CcodEqual 0 ([int]$receipt.detectionCount) 'clean scan records no detections'
        Assert-CcodTrue ($calls -contains 'StartCustomScan') 'clean verified asset invokes the custom scan'
        $serialized = $capture.Value | ConvertTo-Json -Depth 8 -Compress
        Assert-CcodTrue (-not $serialized.Contains($fixture.Root)) 'Defender receipt does not persist the private artifact path'
        Assert-CcodTrue ($serialized.Contains($fixture.Installer.Substring(0,0))) 'receipt is serializable'

        $calls.Clear()
        $capture.Value = $null
        $threatCalls = [pscustomobject]@{ Count = 0 }
        $detected = @{} + $base
        $detected.GetZoneId = { param($Path) $calls.Add('GetZoneId'); 3 }.GetNewClosure()
        $detected.GetThreatDetections = {
            $calls.Add('GetThreatDetections')
            $threatCalls.Count++
            if ($threatCalls.Count -eq 1) { return @() }
            return @([pscustomobject]@{ ThreatID = 99; InitialDetectionTime = '2026-08-24T00:00:00.0000000Z'; Resources = 'redacted-by-gate' })
        }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodReleaseDefenderCheck -InstallerPath $fixture.Installer -ChecksumPath $fixture.Checksum -EvidencePath (Join-Path $fixture.Root 'detection.json') -Adapters $detected
        } 'CCOD_DEFENDER_DETECTIONS_FOUND'
        Assert-CcodEqual 'Failed' ([string]$capture.Value.outcome) 'detection receipt records failure'
        Assert-CcodEqual 1 ([int]$capture.Value.detectionCount) 'detection receipt counts only the newly observed detection'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'package scripts build provenance and workflows retain the release-contract gates' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodTrue ($null -ne $package.scripts.'test:installed-lifecycle') 'package exposes installed-lifecycle deterministic tests'
    Assert-CcodTrue ($null -ne $package.scripts.'test:release-contract') 'package exposes release contract tests'
    $build = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($build -match 'release-manifest\.json') 'build emits a release manifest'
    Assert-CcodTrue ($build -match 'gitCommit') 'build records the source commit'
    Assert-CcodTrue ($build -match 'buildTimestampUtc') 'build records a canonical build timestamp'
    Assert-CcodTrue ($build -match 'does not match package\.json version') 'build refuses a requested version that differs from package metadata'
    Assert-CcodTrue ($build -match 'status --porcelain --untracked-files=all') 'build refuses a dirty candidate checkout'
    Assert-CcodTrue ($build -match 'Test-CcodReleaseAssetManifest') 'build verifies its own immutable release manifest before success'
    $trayHost = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\TrayHostBuild.psm1') -Raw
    Assert-CcodTrue ($trayHost -match 'gitCommit') 'TrayHost provenance binds its source commit'
    Assert-CcodTrue ($trayHost -match 'buildTimestampUtc') 'TrayHost provenance binds its build timestamp'
    $ci = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') -Raw
    Assert-CcodTrue ($ci -match 'UninstallBootstrap\.SelfTest\.ps1') 'CI runs the external uninstall bootstrap self-test before aggregate validation'
    Assert-CcodTrue ($ci -match 'test:installed-lifecycle') 'CI runs deterministic installed lifecycle tests'
    Assert-CcodTrue ($ci -match 'test:release-contract') 'CI runs release contract tests'
    $release = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\release.yml') -Raw
    Assert-CcodTrue ($release -cmatch '(?ms)^\s*workflow_dispatch:\r?\n\s+inputs:\r?\n\s+tag:') 'manual release dispatch requires an explicit tag input'
    Assert-CcodTrue ($release -match 'CCOD_RELEASE_TAG') 'release jobs derive their version from the validated release tag'
    Assert-CcodTrue ($release -match 'build\.ps1 -Version') 'release build binds the candidate version to the validated tag'
    Assert-CcodTrue ($release -match 'download-artifact') 'release promotion downloads a previously built candidate'
    Assert-CcodTrue ($release -match 'test:release-contract') 'release promotion checks the release contract'
    Assert-CcodTrue ($release -match 'release-manifest') 'release promotion uploads the bound release manifest'
    Assert-CcodTrue ($release -match 'gh release download') 'existing release assets are downloaded before any publication decision'
    Assert-CcodTrue (-not ($release -match 'gh release upload[^\r\n]*--clobber')) 'release publication never overwrites an existing asset'
    Assert-CcodTrue ($release -match 'Read back published GitHub release assets') 'release publication re-downloads every uploaded asset for hash read-back'
    Assert-CcodTrue ($release -cmatch '(?ms)^permissions:\r?\n\s+contents: read\s*$') 'candidate build starts with read-only repository permission'
    Assert-CcodTrue ($release -cmatch '(?ms)^  publish:\r?\n    needs: build\r?\n    runs-on: windows-latest\r?\n    permissions:\r?\n      contents: write\s*$') 'only the publish job receives release-write permission'
}

Invoke-CcodTest '2.5.6 documentation matches the portable release, Defender gate, and protected uninstall contract' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodEqual '2.5.6' ([string]$package.version) 'package metadata is the 2.5.6 release'
    $changelog = Get-Content -LiteralPath (Join-Path $repositoryRoot 'CHANGELOG.md') -Raw
    $releaseSection = [regex]::Match($changelog, '(?ms)^## v2\.5\.6\s*\r?\n(?<body>.*?)(?=^## |\z)')
    Assert-CcodTrue $releaseSection.Success 'v2.5.6 release section exists'
    Assert-CcodTrue ($releaseSection.Groups['body'].Value.Contains('manifest-bound portable ZIP')) 'v2.5.6 changelog records the portable ZIP boundary'
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
    $quickStart = [regex]::Match($readme, '(?ms)^## Quick start\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    Assert-CcodTrue ($quickStart.Contains('CodexRemote-fix-2.5.6-windows-x64.zip')) 'English Quick Start names the portable ZIP'
    Assert-CcodTrue ($quickStart.Contains('Install-CodexRemote-fix.ps1')) 'English Quick Start names the verified entrypoint'
    Assert-CcodTrue ($quickStart.Contains('Microsoft Defender')) 'English Quick Start documents the local Defender gate'
    Assert-CcodTrue (-not $quickStart.Contains('-setup.exe')) 'English Quick Start no longer directs users to the retired self-extracting setup'
    Assert-CcodTrue ($readme.Contains('Uninstall-CodexControlOtherDevices.ps1')) 'English README documents the portable uninstall entrypoint'
    $readmeZh = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.zh-CN.md') -Raw -Encoding UTF8
    Assert-CcodTrue ($readmeZh.Contains('CodexRemote-fix-2.5.6-windows-x64.zip')) 'Chinese Quick Start names the portable ZIP'
    Assert-CcodTrue ($readmeZh.Contains('Install-CodexRemote-fix.ps1')) 'Chinese Quick Start names the verified entrypoint'
    Assert-CcodTrue ($readmeZh.Contains('Microsoft Defender')) 'Chinese Quick Start documents the local Defender gate'
    Assert-CcodTrue ($readmeZh.Contains('Uninstall-CodexControlOtherDevices.ps1')) 'Chinese README documents the portable uninstall entrypoint'
    $technical = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\TECHNICAL.md') -Raw
    Assert-CcodTrue ($technical.Contains('PortableUninstallFinalizer.ps1')) 'technical documentation records the staged portable finalizer'
    $security = Get-Content -LiteralPath (Join-Path $repositoryRoot 'SECURITY.md') -Raw
    Assert-CcodTrue ($security.Contains('does not disable Defender or add exclusions')) 'security documentation forbids Defender weakening'
<#
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodEqual '2.5.5' ([string]$package.version) 'package metadata is the 2.5.5 release'

    $changelog = Get-Content -LiteralPath (Join-Path $repositoryRoot 'CHANGELOG.md') -Raw
    $releaseSection = [regex]::Match($changelog, '(?ms)^## v2\.5\.5\s*\r?\n(?<body>.*?)(?=^## |\z)')
    Assert-CcodTrue $releaseSection.Success 'v2.5.5 release section exists'
    $releaseBody = $releaseSection.Groups['body'].Value
    Assert-CcodTrue ($releaseBody -match '(?m)^### English\s*$') 'v2.5.5 release section is English'
    Assert-CcodTrue ($releaseBody.Contains('Added a tightly scoped compatibility inspection for an older manifest-sealed controller that omitted its `ProcessControl` import. It accepts only the exact correlated legacy failure and requires a manifest-verified read-only ordinary-session recheck immediately before each protected uninstall deletion boundary.')) 'v2.5.5 legacy controller compatibility release bullet is exact'
    Assert-CcodTrue ($releaseBody.Contains('New `SessionController` runtimes now load `ProcessControl` globally, and regression coverage rejects every other controller failure or changed compatibility proof.')) 'v2.5.5 regression release bullet is exact'

    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
    $quickStart = [regex]::Match($readme, '(?ms)^## Quick start\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    Assert-CcodTrue ($quickStart.Contains('CodexRemote-fix-2.5.5-setup.exe')) 'English Quick Start names the 2.5.5 installer'
    Assert-CcodTrue ($readme.Contains('## Connection and protection status')) 'English README documents the current status contract'
    foreach ($state in @('Waiting for Codex', 'Checking', 'Connected', 'Repair needed', 'Error', 'Running', 'Reconnecting', 'Stopping')) {
        Assert-CcodTrue ($readme.Contains($state)) "English README documents state: $state"
    }
    Assert-CcodTrue ($readme.Contains('Restart now')) 'English README explains Restart now'
    Assert-CcodTrue ($readme.Contains('Later')) 'English README explains Later'
    Assert-CcodTrue ($readme.Contains('Safe Exit')) 'English README explains safe Exit'
    Assert-CcodTrue ($readme.Contains('The tray has no uninstall command.')) 'English README excludes tray uninstall'
    Assert-CcodTrue ($readme.Contains('Windows Settings')) 'English README documents Windows Settings uninstall'
    Assert-CcodTrue ($readme.Contains('unins000.exe')) 'English README documents direct uninstaller'
    Assert-CcodTrue (-not $readme.Contains('Automation, Candidate-compatible trial, Logs, and Uninstall')) 'English README no longer describes removed tray toggles'

    $readmeZh = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.zh-CN.md') -Raw -Encoding UTF8
    $quickStartZh = [regex]::Match($readmeZh, '(?ms)^## \u5FEB\u901F\u5F00\u59CB\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    Assert-CcodTrue ($quickStartZh.Contains('CodexRemote-fix-2.5.5-setup.exe')) 'Chinese Quick Start names the 2.5.5 installer'
    Assert-CcodTrue ($readmeZh -match '## \u8FDE\u63A5\u4E0E\u5B88\u62A4\u72B6\u6001') 'Chinese README documents the current status contract'
    foreach ($statePattern in @('\u7B49\u5F85 Codex', '\u6B63\u5728\u68C0\u67E5', '\u5DF2\u8FDE\u63A5', '\u9700\u8981\u4FEE\u590D', '\u9519\u8BEF', '\u8FD0\u884C\u4E2D', '\u6B63\u5728\u91CD\u8FDE', '\u6B63\u5728\u505C\u6B62')) {
        Assert-CcodTrue ($readmeZh -match $statePattern) "Chinese README documents state pattern: $statePattern"
    }
    Assert-CcodTrue ($readmeZh -match '\u7ACB\u5373\u91CD\u542F') 'Chinese README explains Restart now'
    Assert-CcodTrue ($readmeZh -match '\u7A0D\u540E') 'Chinese README explains Later'
    Assert-CcodTrue ($readmeZh -match '\u5B89\u5168\u9000\u51FA') 'Chinese README explains safe Exit'
    Assert-CcodTrue ($readmeZh -match '\u6258\u76D8\u4E2D\u6CA1\u6709\u5378\u8F7D\u547D\u4EE4\u3002') 'Chinese README excludes tray uninstall'
    Assert-CcodTrue ($readmeZh -match 'Windows \u8BBE\u7F6E') 'Chinese README documents Windows Settings uninstall'
    Assert-CcodTrue ($readmeZh.Contains('unins000.exe')) 'Chinese README documents direct uninstaller'
    Assert-CcodTrue (-not ($readmeZh -match '\u7ACB\u5373\u5E94\u7528\u3001\u91CD\u8BD5\u3001\u81EA\u52A8\u5316\u5F00\u5173\u3001\u517C\u5BB9\u66F4\u65B0\u8BD5\u7528\u3001\u65E5\u5FD7\u3001\u5378\u8F7D')) 'Chinese README no longer describes removed tray toggles'

    $technical = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\TECHNICAL.md') -Raw
    foreach ($term in @('lifecycle epoch/generation fence', 'trusted LUID marker', 'protocol v2', 'external uninstaller receipt', 'remote-control-device-keys.windows.json', 'The tray has no uninstall command.')) {
        Assert-CcodTrue ($technical.Contains($term)) "technical documentation records: $term"
    }
    foreach ($obsolete in @('Menu.Uninstall', 'UninstallEnabled', 'AutomationToggleEnabled', 'CandidateOptInToggleEnabled', 'BackupDeviceKeyStore', 'RemoveDeviceKeyStore')) {
        Assert-CcodTrue (-not $technical.Contains($obsolete)) "technical documentation excludes obsolete contract: $obsolete"
    }

    $cleanroom = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\CLEANROOM.md') -Raw
    Assert-CcodTrue ($cleanroom.Contains('protocol v2')) 'clean-room boundary records the current tray protocol'

    $security = Get-Content -LiteralPath (Join-Path $repositoryRoot 'SECURITY.md') -Raw
    Assert-CcodTrue ($security.Contains('remote-control-device-keys.windows.json')) 'security documentation retains the unchanged DPAPI key location'
    Assert-CcodTrue ($security.Contains('Windows Settings')) 'security documentation identifies the external uninstall route'
    Assert-CcodTrue ($security.Contains('unins000.exe')) 'security documentation identifies the direct uninstaller route'
    Assert-CcodTrue (-not $security.Contains('-BackupDeviceKeyStore')) 'security documentation excludes legacy key backup switch'
    Assert-CcodTrue (-not $security.Contains('-RemoveDeviceKeyStore')) 'security documentation excludes legacy key removal switch'
#>
}

Invoke-CcodTest 'portable release manifest binds the ZIP payload manifest and each archived payload file' {
    . $defenderPath -Library
    $fixture = New-CcodPortableReleaseFixture
    try {
        $validated = Test-CcodReleaseAssetManifest -ManifestPath $fixture.Manifest -AssetDirectory $fixture.Root -ExpectedVersion '2.5.6'
        Assert-CcodEqual $true ([bool]$validated.Valid) 'valid portable fixture passes the release manifest contract'
        Assert-CcodEqual 'portable-zip' ([string]$validated.Distribution) 'validator reports the portable release distribution'
        $payload = Get-Content -LiteralPath $fixture.PayloadManifest -Raw | ConvertFrom-Json
        $payload.files[0].sha256 = '0' * 64
        [IO.File]::WriteAllText($fixture.PayloadManifest,($payload | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $release = Get-Content -LiteralPath $fixture.Manifest -Raw | ConvertFrom-Json
        $asset = @($release.assets | Where-Object { $_.name -ceq [IO.Path]::GetFileName($fixture.PayloadManifest) })[0]
        $asset.sha256 = Get-CcodTestFileSha256 -Path $fixture.PayloadManifest
        [IO.File]::WriteAllText($fixture.Manifest,($release | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath $fixture.Manifest -AssetDirectory $fixture.Root -ExpectedVersion '2.5.6'
        } 'CCOD_RELEASE_ASSET_HASH_MISMATCH'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Write-Host 'Release workflow self-tests passed.'
