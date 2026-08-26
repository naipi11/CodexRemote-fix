$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$lockPath=Join-Path $repositoryRoot 'build\trayhost-packages.lock.json'

Invoke-CcodTest '2.5.18 source metadata binds the package and native assembly identities' {
    $package=Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw|ConvertFrom-Json
    Assert-CcodEqual '2.5.18' ([string]$package.version) 'package version is the 2.5.18 release version'
    $assemblyInfo=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\trayhost\AssemblyInfo.cs') -Raw
    Assert-CcodTrue ($assemblyInfo -match 'AssemblyVersion\("2\.5\.18\.0"\)') 'TrayHost assembly version is 2.5.18.0'
    Assert-CcodTrue ($assemblyInfo -match 'AssemblyFileVersion\("2\.5\.18\.0"\)') 'TrayHost file version is 2.5.18.0'
    $manifest=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\trayhost\CodexRemote.TrayHost.manifest') -Raw
    Assert-CcodTrue ($manifest -match '<assemblyIdentity version="2\.5\.18\.0"') 'TrayHost manifest identity is 2.5.18.0'
    $portableManifest=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\portable\CodexRemote.Portable.manifest') -Raw
    Assert-CcodTrue ($portableManifest -match '<assemblyIdentity version="2\.5\.18\.0"') 'portable launcher manifest identity is 2.5.18.0'
    $portableAssemblyInfo=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\portable\AssemblyInfo.cs') -Raw
    Assert-CcodTrue ($portableAssemblyInfo -match 'AssemblyVersion\("2\.5\.18\.0"\)') 'portable launcher assembly version is 2.5.18.0'
    Assert-CcodTrue ($portableAssemblyInfo -match 'AssemblyFileVersion\("2\.5\.18\.0"\)') 'portable launcher file version is 2.5.18.0'
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
        $result=Invoke-CcodTrayHostBuild -RepositoryRoot $repositoryRoot -Version '2.5.18' -OutputDirectory $artifact
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.TrayHost.exe') -PathType Leaf) 'TrayHost executable exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.TrayHost.exe.config') -PathType Leaf) 'TrayHost config exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'trayhost-build-provenance.json') -PathType Leaf) 'TrayHost provenance exists'
        $provenance=Get-Content -LiteralPath (Join-Path $artifact 'trayhost-build-provenance.json') -Raw|ConvertFrom-Json
        Assert-CcodEqual '2.5.18' ([string]$provenance.version) 'provenance version is exact'
        $fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $artifact 'CodexRemote.TrayHost.exe')).FileVersion
        Assert-CcodEqual '2.5.18.0' ([string]$fileVersion) 'built TrayHost file version is release-aligned'
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
        $validated=Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.18' -ArtifactDirectory $artifact -ExpectedGitCommit $currentCommit
        Assert-CcodEqual $currentCommit ([string]$validated.GitCommit) 'artifact validation binds the current source commit when requested'
        $tampered=Join-Path $artifact 'CodexRemote.TrayHost.exe.config'; Add-Content -LiteralPath $tampered -Value 'x'
        $threw=$false; try{Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.18' -ArtifactDirectory $artifact|Out-Null}catch{$threw=$true}
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
    try {
        $result = Invoke-CcodPortableLauncherBuild -RepositoryRoot $repositoryRoot -Version '2.5.18' -OutputDirectory $artifact
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.Portable.exe') -PathType Leaf) 'portable launcher executable exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'CodexRemote.Portable.exe.config') -PathType Leaf) 'portable launcher config exists'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $artifact 'portable-launcher-provenance.json') -PathType Leaf) 'portable launcher provenance exists'
        $provenance = Get-Content -LiteralPath (Join-Path $artifact 'portable-launcher-provenance.json') -Raw | ConvertFrom-Json
        Assert-CcodEqual '2.5.18' ([string]$provenance.version) 'portable launcher provenance version is exact'
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $artifact 'CodexRemote.Portable.exe'))
        Assert-CcodEqual '2.5.18.0' ([string]$fileVersion.FileVersion) 'portable launcher Windows file version is release-aligned'
        Assert-CcodEqual '2.5.18.0' ([string]$fileVersion.ProductVersion) 'portable launcher Windows product version is release-aligned'
        Assert-CcodEqual 2 @($provenance.sourceFiles).Count 'portable launcher provenance binds both implementation and assembly metadata'
        Assert-CcodTrue (@($provenance.sourceFiles.name) -ccontains 'AssemblyInfo.cs') 'portable launcher provenance includes assembly metadata'
        $validated = (Get-FileHash -LiteralPath (Join-Path $artifact 'CodexRemote.Portable.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-CcodEqual $validated ([string]$provenance.artifactSha256) 'portable launcher artifact binds its executable hash'
    } finally {
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host 'TrayHost build self-tests passed.'
