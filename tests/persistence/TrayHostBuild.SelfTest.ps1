$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$lockPath=Join-Path $repositoryRoot 'build\trayhost-packages.lock.json'

Invoke-CcodTest 'TrayHost artifact validation binds the manifest and embedded PE version to the requested release' {
    Import-Module (Join-Path $repositoryRoot 'build\TrayHostBuild.psm1') -Force
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    $version = [string]$package.version
    $nativeVersion = "$version.0"
    $artifact = Join-Path $env:TEMP ('ccod-native-version-artifact-' + [Guid]::NewGuid().ToString('N'))
    $fixtureRoot = Join-Path $env:TEMP ('ccod-native-version-repository-' + [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-CcodTrayHostBuild -RepositoryRoot $repositoryRoot -Version $version -OutputDirectory $artifact -GitCommit ('b' * 40) -BuildTimestampUtc '2026-08-28T00:00:00.0000000Z' | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'src')) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\trayhost') -Destination (Join-Path $fixtureRoot 'src\trayhost') -Recurse
        [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'assets\codexremote-fix')) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'assets\codexremote-fix\codexremote-fix.ico') -Destination (Join-Path $fixtureRoot 'assets\codexremote-fix\codexremote-fix.ico')
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'package.json') -Destination (Join-Path $fixtureRoot 'package.json')

        $manifestPath = Join-Path $fixtureRoot 'src\trayhost\CodexRemote.TrayHost.manifest'
        $manifestBaseline = [IO.File]::ReadAllText($manifestPath,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manifestPath,$manifestBaseline.Replace('</assembly>','<!-- byte mutation with unchanged identity --></assembly>'),[Text.UTF8Encoding]::new($false))
        $manifestHashError = ''
        try { Test-CcodTrayHostArtifact -RepositoryRoot $fixtureRoot -Version $version -ArtifactDirectory $artifact -ExpectedGitCommit ('b' * 40) | Out-Null }
        catch { $manifestHashError = ([string]$_.FullyQualifiedErrorId -split ',')[0] }

        [IO.File]::WriteAllText($manifestPath,$manifestBaseline.Replace($nativeVersion,'9.9.9.0'),[Text.UTF8Encoding]::new($false))
        $manifestError = ''
        try { Test-CcodTrayHostArtifact -RepositoryRoot $fixtureRoot -Version $version -ArtifactDirectory $artifact -ExpectedGitCommit ('b' * 40) | Out-Null }
        catch { $manifestError = ([string]$_.FullyQualifiedErrorId -split ',')[0] }

        [IO.File]::WriteAllText($manifestPath,$manifestBaseline.Replace($nativeVersion,'9.9.9.0'),[Text.UTF8Encoding]::new($false))
        $assemblyPath = Join-Path $fixtureRoot 'src\trayhost\AssemblyInfo.cs'
        $assembly = [IO.File]::ReadAllText($assemblyPath,[Text.UTF8Encoding]::new($false)).Replace($nativeVersion,'9.9.9.0')
        [IO.File]::WriteAllText($assemblyPath,$assembly,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'package.json'),'{"version":"9.9.9"}',[Text.UTF8Encoding]::new($false))
        $provenancePath = Join-Path $artifact 'trayhost-build-provenance.json'
        $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
        $provenance.version = '9.9.9'
        $assemblyRecord = @($provenance.sourceFiles | Where-Object { $_.name -ceq 'AssemblyInfo.cs' })[0]
        $assemblyRecord.sha256 = Get-CcodTestFileSha256 -Path $assemblyPath
        $provenance.manifestSha256 = Get-CcodTestFileSha256 -Path $manifestPath
        [IO.File]::WriteAllText($provenancePath,($provenance | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $peError = ''
        try { Test-CcodTrayHostArtifact -RepositoryRoot $fixtureRoot -Version '9.9.9' -ArtifactDirectory $artifact -ExpectedGitCommit ('b' * 40) | Out-Null }
        catch { $peError = ([string]$_.FullyQualifiedErrorId -split ',')[0] }

        Assert-CcodEqual 'CCOD_TRAYHOST_ARTIFACT_TAMPERED|CCOD_TRAYHOST_VERSION_MISMATCH|CCOD_TRAYHOST_ARTIFACT_VERSION_INVALID' "$manifestHashError|$manifestError|$peError" 'validator binds manifest bytes and rejects static or PE version drift'
    } finally {
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest 'native build entrypoints reject mismatched package AssemblyInfo and manifest versions before compilation' {
    Import-Module (Join-Path $repositoryRoot 'build\TrayHostBuild.psm1') -Force
    $root = Join-Path $env:TEMP ('ccod-native-version-contract-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $cases = @(
            [pscustomobject]@{ Component='trayhost'; PackageVersion='9.9.9'; AssemblyVersion='2.5.22.0'; FileVersion='2.5.22.0'; ManifestVersion='2.5.22.0'; ExpectedError='CCOD_TRAYHOST_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='trayhost'; PackageVersion='2.5.22'; AssemblyVersion='9.9.9.0'; FileVersion='2.5.22.0'; ManifestVersion='2.5.22.0'; ExpectedError='CCOD_TRAYHOST_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='trayhost'; PackageVersion='2.5.22'; AssemblyVersion='2.5.22.0'; FileVersion='9.9.9.0'; ManifestVersion='2.5.22.0'; ExpectedError='CCOD_TRAYHOST_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='trayhost'; PackageVersion='2.5.22'; AssemblyVersion='2.5.22.0'; FileVersion='2.5.22.0'; ManifestVersion='9.9.9.0'; ExpectedError='CCOD_TRAYHOST_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='portable'; PackageVersion='9.9.9'; AssemblyVersion='2.5.22.0'; FileVersion='2.5.22.0'; ManifestVersion='2.5.22.0'; ExpectedError='CCOD_PORTABLE_LAUNCHER_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='portable'; PackageVersion='2.5.22'; AssemblyVersion='9.9.9.0'; FileVersion='2.5.22.0'; ManifestVersion='2.5.22.0'; ExpectedError='CCOD_PORTABLE_LAUNCHER_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='portable'; PackageVersion='2.5.22'; AssemblyVersion='2.5.22.0'; FileVersion='9.9.9.0'; ManifestVersion='2.5.22.0'; ExpectedError='CCOD_PORTABLE_LAUNCHER_VERSION_MISMATCH' },
            [pscustomobject]@{ Component='portable'; PackageVersion='2.5.22'; AssemblyVersion='2.5.22.0'; FileVersion='2.5.22.0'; ManifestVersion='9.9.9.0'; ExpectedError='CCOD_PORTABLE_LAUNCHER_VERSION_MISMATCH' }
        )
        foreach ($case in $cases) {
            [IO.File]::WriteAllText((Join-Path $root 'package.json'),("{{`"version`":`"{0}`"}}" -f $case.PackageVersion),[Text.UTF8Encoding]::new($false))
            $sourceRoot = Join-Path $root ('src\' + $case.Component)
            [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
            $assemblyInfo = "using System.Reflection;`r`n[assembly: AssemblyVersion(`"$($case.AssemblyVersion)`")]`r`n[assembly: AssemblyFileVersion(`"$($case.FileVersion)`")]`r`n"
            [IO.File]::WriteAllText((Join-Path $sourceRoot 'AssemblyInfo.cs'),$assemblyInfo,[Text.UTF8Encoding]::new($false))
            $manifestName = if ($case.Component -ceq 'trayhost') { 'CodexRemote.TrayHost.manifest' } else { 'CodexRemote.Portable.manifest' }
            $identityName = if ($case.Component -ceq 'trayhost') { 'CodexRemote.fix.TrayHost' } else { 'CodexRemote.fix.Portable' }
            $manifest = "<?xml version=`"1.0`" encoding=`"utf-8`"?><assembly manifestVersion=`"1.0`" xmlns=`"urn:schemas-microsoft-com:asm.v1`"><assemblyIdentity version=`"$($case.ManifestVersion)`" name=`"$identityName`" type=`"win32`" /></assembly>"
            [IO.File]::WriteAllText((Join-Path $sourceRoot $manifestName),$manifest,[Text.UTF8Encoding]::new($false))
            $actualError = ''
            try {
                if ($case.Component -ceq 'trayhost') {
                    Invoke-CcodTrayHostBuild -RepositoryRoot $root -Version '2.5.22' -OutputDirectory (Join-Path $root 'trayhost-out') -GitCommit ('a' * 40) -BuildTimestampUtc '2026-08-28T00:00:00.0000000Z' | Out-Null
                } else {
                    Invoke-CcodPortableLauncherBuild -RepositoryRoot $root -Version '2.5.22' -OutputDirectory (Join-Path $root 'portable-out') -GitCommit ('a' * 40) -BuildTimestampUtc '2026-08-28T00:00:00.0000000Z' | Out-Null
                }
            } catch {
                $actualError = ([string]$_.FullyQualifiedErrorId -split ',')[0]
            }
            Assert-CcodEqual ([string]$case.ExpectedError) $actualError "$($case.Component) rejects $($case.PackageVersion)/$($case.AssemblyVersion)/$($case.FileVersion)/$($case.ManifestVersion) before resolving compiler inputs"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest '2.5.22 source metadata binds the package and native assembly identities' {
    $package=Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw|ConvertFrom-Json
    Assert-CcodEqual '2.5.22' ([string]$package.version) 'package version is the 2.5.22 release version'
    $assemblyInfo=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\trayhost\AssemblyInfo.cs') -Raw
    Assert-CcodTrue ($assemblyInfo -match 'AssemblyVersion\("2\.5\.22\.0"\)') 'TrayHost assembly version is 2.5.22.0'
    Assert-CcodTrue ($assemblyInfo -match 'AssemblyFileVersion\("2\.5\.22\.0"\)') 'TrayHost file version is 2.5.22.0'
    $manifest=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\trayhost\CodexRemote.TrayHost.manifest') -Raw
    Assert-CcodTrue ($manifest -match '<assemblyIdentity version="2\.5\.22\.0"') 'TrayHost manifest identity is 2.5.22.0'
    $portableManifest=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\portable\CodexRemote.Portable.manifest') -Raw
    Assert-CcodTrue ($portableManifest -match '<assemblyIdentity version="2\.5\.22\.0"') 'portable launcher manifest identity is 2.5.22.0'
    $portableAssemblyInfo=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\portable\AssemblyInfo.cs') -Raw
    Assert-CcodTrue ($portableAssemblyInfo -match 'AssemblyVersion\("2\.5\.22\.0"\)') 'portable launcher assembly version is 2.5.22.0'
    Assert-CcodTrue ($portableAssemblyInfo -match 'AssemblyFileVersion\("2\.5\.22\.0"\)') 'portable launcher file version is 2.5.22.0'
}

Invoke-CcodTest 'TrayHost build lock pins the Microsoft net48 reference package' {
    Assert-CcodTrue (Test-Path -LiteralPath $lockPath -PathType Leaf) 'TrayHost reference lock exists'
    $lock=Get-Content -LiteralPath $lockPath -Raw|ConvertFrom-Json
    Assert-CcodEqual 1 ([int]$lock.schemaVersion) 'reference lock schema is exact'
    Assert-CcodEqual 1 @($lock.packages).Count 'reference lock has one package'
    $package=@($lock.packages)[0]
    Assert-CcodEqual 'Microsoft.NETFramework.ReferenceAssemblies.net48' ([string]$package.id) 'reference package id is exact'
    Assert-CcodEqual '1.0.3' ([string]$package.version) 'reference package version is exact'
    Assert-CcodEqual 'XWKgyeNadNcTQaIVvQB8BrdCNrEar6fo/de1OdQRZ9HFy0jcBSaM8IV5q64ZampsSnC8AlTsACaGZUuoFw41RA==' ([string]$package.sha512) 'reference package SHA-512 is exact'
}

Invoke-CcodTest 'TrayHost resolver returns only the locked reference directory and rejects a mutated lock' {
    Import-Module (Join-Path $repositoryRoot 'build\TrayHostReferencePack.psm1') -Force
    $cache=Join-Path $env:TEMP 'ccod-trayhost-reference-pack'
    $resolved=Resolve-CcodTrayHostReferencePack -LockPath $lockPath -CacheRoot $cache
    Assert-CcodTrue ([IO.Path]::GetFullPath($resolved.ReferenceRoot).StartsWith([IO.Path]::GetFullPath($cache),[StringComparison]::OrdinalIgnoreCase)) 'resolver stays under its cache root'
    foreach($leaf in @('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll')){Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $resolved.ReferenceRoot $leaf) -PathType Leaf) "locked reference exists: $leaf"}
    $mutated=[IO.Path]::GetTempFileName()
    try{
        $json=Get-Content -LiteralPath $lockPath -Raw|ConvertFrom-Json
        $json.packages[0].sha512='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='
        $json|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $mutated -Encoding UTF8
        $threw=$false
        try{Resolve-CcodTrayHostReferencePack -LockPath $mutated -CacheRoot $cache|Out-Null}catch{ $threw=([string]$_.FullyQualifiedErrorId -split ',')[0] -ceq 'CCOD_TRAYHOST_REFERENCE_LOCK_INVALID' }
        Assert-CcodTrue $threw 'mutated reference lock is rejected'
    }finally{Remove-Item -LiteralPath $mutated -Force -ErrorAction SilentlyContinue}
}

Invoke-CcodTest 'TrayHost build emits one source-auditable artifact and rejects tampering' {
    $modulePath=Join-Path $repositoryRoot 'build\TrayHostBuild.psm1'
    Assert-CcodTrue (Test-Path -LiteralPath $modulePath -PathType Leaf) 'TrayHost build module exists'
    Import-Module $modulePath -Force
    $artifact=Join-Path $env:TEMP ('ccod-trayhost-artifact-'+[Guid]::NewGuid().ToString('N'))
    try{
        $result=Invoke-CcodTrayHostBuild -RepositoryRoot $repositoryRoot -Version '2.5.22' -OutputDirectory $artifact
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.TrayHost.exe') -PathType Leaf) 'TrayHost executable exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.TrayHost.exe.config') -PathType Leaf) 'TrayHost config exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'trayhost-build-provenance.json') -PathType Leaf) 'TrayHost provenance exists'
        $provenance=Get-Content -LiteralPath (Join-Path $artifact 'trayhost-build-provenance.json') -Raw|ConvertFrom-Json
        Assert-CcodEqual '2.5.22' ([string]$provenance.version) 'provenance version is exact'
        $fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $artifact 'CodexRemote.TrayHost.exe'))
        Assert-CcodEqual '2.5.22.0' ([string]$fileVersion.FileVersion) 'built TrayHost file version is release-aligned'
        Assert-CcodEqual '2.5.22.0' ([string]$fileVersion.ProductVersion) 'built TrayHost product version is release-aligned'
        Assert-CcodTrue ([string]$provenance.gitCommit -cmatch '^[0-9a-f]{40}$') 'provenance records one canonical source commit'
        $provenanceTimestamp=[datetime]::MinValue
        Assert-CcodTrue ([datetime]::TryParse([string]$provenance.buildTimestampUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$provenanceTimestamp)) 'provenance records a parseable build timestamp'
        Assert-CcodEqual $provenanceTimestamp.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) ([string]$provenance.buildTimestampUtc) 'provenance timestamp is canonical UTC'
        $icon=Join-Path $repositoryRoot 'assets\codexremote-fix\codexremote-fix.ico'
        Assert-CcodTrue (Test-Path -LiteralPath $icon -PathType Leaf) 'TrayHost product ICO exists'
        $iconSha=[Security.Cryptography.SHA256]::Create();try{$iconHash=([BitConverter]::ToString($iconSha.ComputeHash([IO.File]::ReadAllBytes($icon)))).Replace('-','').ToLowerInvariant()}finally{$iconSha.Dispose()}
        Assert-CcodEqual $iconHash ([string]$provenance.iconSha256) 'provenance records the embedded product ICO hash'
        Assert-CcodTrue (@($provenance.sourceFiles).Count -ge 10) 'provenance includes every TrayHost source'
        Assert-CcodTrue (-not ([string]$provenance|Select-String -Pattern '[A-Za-z]:\\|\\\\' -Quiet)) 'provenance does not leak absolute paths'
        $currentCommit=(& git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
        $validated=Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact -ExpectedGitCommit $currentCommit
        Assert-CcodEqual $currentCommit ([string]$validated.GitCommit) 'artifact validation binds the current source commit when requested'
        $expectedSourceNames=@(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src\trayhost') -Filter '*.cs' -File|Sort-Object Name|ForEach-Object Name)
        Assert-CcodEqual ($expectedSourceNames -join ',') (@($provenance.sourceFiles.name) -join ',') 'built provenance records the exact compiled TrayHost source set in canonical order'
        Assert-CcodTrue ($expectedSourceNames -ccontains 'TrayHostChildSession.cs') 'compiled source provenance includes the shared production child session'
        Assert-CcodTrue ($expectedSourceNames -ccontains 'WindowsTrayHostRuntime.cs') 'compiled source provenance includes the production Windows runtime adapter'
        $provenancePath=Join-Path $artifact 'trayhost-build-provenance.json'
        $baselineJson=[IO.File]::ReadAllText($provenancePath,[Text.UTF8Encoding]::new($false))
        $mutations=@(
            [pscustomobject]@{Name='missing shared child session';Apply={param($record)$record.sourceFiles=@($record.sourceFiles|Where-Object{$_.name -cne 'TrayHostChildSession.cs'})}},
            [pscustomobject]@{Name='duplicate shared child session';Apply={param($record)$child=@($record.sourceFiles|Where-Object{$_.name -ceq 'TrayHostChildSession.cs'})[0];$record.sourceFiles=@($record.sourceFiles|Where-Object{$_.name -cne 'WindowsTrayHostRuntime.cs'})+@([pscustomobject]@{name=$child.name;sha256=$child.sha256})}},
            [pscustomobject]@{Name='different source name set';Apply={param($record)$child=@($record.sourceFiles|Where-Object{$_.name -ceq 'TrayHostChildSession.cs'})[0];$child.name='TrayHostChildSession-copy.cs'}},
            [pscustomobject]@{Name='Windows runtime source hash mismatch';Apply={param($record)$runtime=@($record.sourceFiles|Where-Object{$_.name -ceq 'WindowsTrayHostRuntime.cs'})[0];$runtime.sha256='0'*64}}
        )
        foreach($mutationCase in $mutations){
            $mutated=$baselineJson|ConvertFrom-Json
            $applyMutation=[scriptblock]$mutationCase.Apply
            & $applyMutation $mutated
            [IO.File]::WriteAllText($provenancePath,($mutated|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            try{
                Assert-CcodThrows { Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact -ExpectedGitCommit $currentCommit|Out-Null } 'CCOD_TRAYHOST_SOURCE_TAMPERED'
            }finally{
                [IO.File]::WriteAllText($provenancePath,$baselineJson,[Text.UTF8Encoding]::new($false))
            }
        }
        $tampered=Join-Path $artifact 'CodexRemote.TrayHost.exe.config'; Add-Content -LiteralPath $tampered -Value 'x'
        $threw=$false; try{Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact|Out-Null}catch{$threw=$true}
        Assert-CcodTrue $threw 'tampered artifact is rejected'
    }finally{if(Test-Path -LiteralPath $artifact){Remove-Item -LiteralPath $artifact -Recurse -Force -ErrorAction SilentlyContinue}}
}

Invoke-CcodTest 'TrayHost build embeds the product ICO instead of relying on a runtime path' {
    $build=Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\TrayHostBuild.psm1') -Raw
    Assert-CcodTrue ($build -match 'win32icon') 'TrayHost compiler embeds an ICO'
    Assert-CcodTrue ($build -match 'codexremote-fix\.ico') 'TrayHost compiler uses the product ICO'
}

Invoke-CcodTest 'portable launcher build emits a tamper-bound double-click entrypoint' {
    Import-Module (Join-Path $repositoryRoot 'build\TrayHostBuild.psm1') -Force
    $artifact = Join-Path $env:TEMP ('ccod-portable-launcher-artifact-' + [Guid]::NewGuid().ToString('N'))
    $fixtureRoot = Join-Path $env:TEMP ('ccod-portable-launcher-repository-' + [Guid]::NewGuid().ToString('N'))
    try {
        $result = Invoke-CcodPortableLauncherBuild -RepositoryRoot $repositoryRoot -Version '2.5.22' -OutputDirectory $artifact
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.Portable.exe') -PathType Leaf) 'portable launcher executable exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.Portable.exe.config') -PathType Leaf) 'portable launcher config exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'portable-launcher-provenance.json') -PathType Leaf) 'portable launcher provenance exists'
        $provenance = Get-Content -LiteralPath (Join-Path $artifact 'portable-launcher-provenance.json') -Raw | ConvertFrom-Json
        Assert-CcodEqual '2.5.22' ([string]$provenance.version) 'portable launcher provenance version is exact'
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $artifact 'CodexRemote.Portable.exe'))
        Assert-CcodEqual '2.5.22.0' ([string]$fileVersion.FileVersion) 'portable launcher Windows file version is release-aligned'
        Assert-CcodEqual '2.5.22.0' ([string]$fileVersion.ProductVersion) 'portable launcher Windows product version is release-aligned'
        Assert-CcodEqual 2 @($provenance.sourceFiles).Count 'portable launcher provenance binds both implementation and assembly metadata'
        Assert-CcodTrue (@($provenance.sourceFiles.name) -ccontains 'AssemblyInfo.cs') 'portable launcher provenance includes assembly metadata'
        $validated = (Get-FileHash -LiteralPath (Join-Path $artifact 'CodexRemote.Portable.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-CcodEqual $validated ([string]$provenance.artifactSha256) 'portable launcher artifact binds its executable hash'
        $currentCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
        $artifactValidation = Test-CcodPortableLauncherArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact -ExpectedGitCommit $currentCommit
        Assert-CcodEqual $currentCommit ([string]$artifactValidation.GitCommit) 'portable artifact validator binds the expected source commit'

        $provenancePath = Join-Path $artifact 'portable-launcher-provenance.json'
        $baselineJson = [IO.File]::ReadAllText($provenancePath,[Text.UTF8Encoding]::new($false))
        $mutations = @(
            [pscustomobject]@{ Name='commit'; Error='CCOD_PORTABLE_LAUNCHER_PROVENANCE_INVALID'; Apply={param($record)$record.gitCommit='d'*40} },
            [pscustomobject]@{ Name='timestamp'; Error='CCOD_PORTABLE_LAUNCHER_PROVENANCE_INVALID'; Apply={param($record)$record.buildTimestampUtc='not-canonical'} },
            [pscustomobject]@{ Name='source hash'; Error='CCOD_PORTABLE_LAUNCHER_SOURCE_TAMPERED'; Apply={param($record)$record.sourceFiles[0].sha256='0'*64} },
            [pscustomobject]@{ Name='icon hash'; Error='CCOD_PORTABLE_LAUNCHER_ARTIFACT_TAMPERED'; Apply={param($record)$record.iconSha256='0'*64} },
            [pscustomobject]@{ Name='manifest hash'; Error='CCOD_PORTABLE_LAUNCHER_ARTIFACT_TAMPERED'; Apply={param($record)$record.manifestSha256='0'*64} },
            [pscustomobject]@{ Name='source config hash'; Error='CCOD_PORTABLE_LAUNCHER_ARTIFACT_TAMPERED'; Apply={param($record)$record.configSha256='0'*64} },
            [pscustomobject]@{ Name='executable hash'; Error='CCOD_PORTABLE_LAUNCHER_ARTIFACT_TAMPERED'; Apply={param($record)$record.artifactSha256='0'*64} },
            [pscustomobject]@{ Name='artifact config hash'; Error='CCOD_PORTABLE_LAUNCHER_ARTIFACT_TAMPERED'; Apply={param($record)$record.configArtifactSha256='0'*64} }
        )
        foreach ($mutationCase in $mutations) {
            $mutated = $baselineJson | ConvertFrom-Json
            & ([scriptblock]$mutationCase.Apply) $mutated
            [IO.File]::WriteAllText($provenancePath,($mutated | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            try {
                Assert-CcodThrows { Test-CcodPortableLauncherArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact -ExpectedGitCommit $currentCommit | Out-Null } ([string]$mutationCase.Error)
            } finally {
                [IO.File]::WriteAllText($provenancePath,$baselineJson,[Text.UTF8Encoding]::new($false))
            }
        }

        [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'src')) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\portable') -Destination (Join-Path $fixtureRoot 'src\portable') -Recurse
        [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'assets\codexremote-fix')) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'assets\codexremote-fix\codexremote-fix.ico') -Destination (Join-Path $fixtureRoot 'assets\codexremote-fix\codexremote-fix.ico')
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'package.json'),'{"version":"9.9.9"}',[Text.UTF8Encoding]::new($false))
        $assemblyPath = Join-Path $fixtureRoot 'src\portable\AssemblyInfo.cs'
        [IO.File]::WriteAllText($assemblyPath,([IO.File]::ReadAllText($assemblyPath,[Text.UTF8Encoding]::new($false)).Replace('2.5.22.0','9.9.9.0')),[Text.UTF8Encoding]::new($false))
        $manifestPath = Join-Path $fixtureRoot 'src\portable\CodexRemote.Portable.manifest'
        [IO.File]::WriteAllText($manifestPath,([IO.File]::ReadAllText($manifestPath,[Text.UTF8Encoding]::new($false)).Replace('2.5.22.0','9.9.9.0')),[Text.UTF8Encoding]::new($false))
        $falseVersion = $baselineJson | ConvertFrom-Json
        $falseVersion.version = '9.9.9'
        @($falseVersion.sourceFiles | Where-Object { $_.name -ceq 'AssemblyInfo.cs' })[0].sha256 = Get-CcodTestFileSha256 -Path $assemblyPath
        $falseVersion.manifestSha256 = Get-CcodTestFileSha256 -Path $manifestPath
        [IO.File]::WriteAllText($provenancePath,($falseVersion | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Test-CcodPortableLauncherArtifact -RepositoryRoot $fixtureRoot -Version '9.9.9' -ArtifactDirectory $artifact -ExpectedGitCommit $currentCommit | Out-Null } 'CCOD_PORTABLE_LAUNCHER_ARTIFACT_VERSION_INVALID'
    } finally {
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host 'TrayHost build self-tests passed.'
