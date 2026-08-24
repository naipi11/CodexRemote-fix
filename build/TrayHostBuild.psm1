Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-CcodTrayHostHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$stream=[IO.File]::OpenRead([IO.Path]::GetFullPath($Path));try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose()}}finally{$sha.Dispose()}
}

function Get-CcodTrayHostGitCommit {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $commit=@(& git -C $RepositoryRoot rev-parse HEAD 2>$null)
    if($LASTEXITCODE -ne 0 -or $commit.Count -ne 1 -or [string]$commit[0] -cnotmatch '^[0-9a-f]{40}$'){throw 'CCOD_TRAYHOST_PROVENANCE_INVALID'}
    return ([string]$commit[0]).ToLowerInvariant()
}

function Test-CcodTrayHostCanonicalUtc {
    param([AllowNull()][string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $false}
    $parsed=[datetime]::MinValue
    if(-not [datetime]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){return $false}
    return $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Get-CcodTrayHostCompiler {
    $candidates=@((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
    $compiler=$candidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
    if($null -eq $compiler){throw 'CCOD_TRAYHOST_COMPILER_MISSING'}
    return $compiler
}

function Test-CcodTrayHostOutputDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if([string]::IsNullOrWhiteSpace($full) -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'CCOD_TRAYHOST_OUTPUT_PATH_INVALID'}
}

function Invoke-CcodTrayHostBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$GitCommit,
        [string]$BuildTimestampUtc
    )
    if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'CCOD_TRAYHOST_VERSION_INVALID'}
    $repo=[IO.Path]::GetFullPath($RepositoryRoot);$out=[IO.Path]::GetFullPath($OutputDirectory);Test-CcodTrayHostOutputDirectory $out
    if([string]::IsNullOrWhiteSpace($GitCommit)){$GitCommit=Get-CcodTrayHostGitCommit -RepositoryRoot $repo}else{$GitCommit=$GitCommit.ToLowerInvariant()}
    if($GitCommit -cnotmatch '^[0-9a-f]{40}$'){throw 'CCOD_TRAYHOST_PROVENANCE_INVALID'}
    if([string]::IsNullOrWhiteSpace($BuildTimestampUtc)){$BuildTimestampUtc=[datetime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
    if(-not (Test-CcodTrayHostCanonicalUtc $BuildTimestampUtc)){throw 'CCOD_TRAYHOST_PROVENANCE_INVALID'}
    $sourceRoot=Join-Path $repo 'src\trayhost';$manifest=Join-Path $sourceRoot 'CodexRemote.TrayHost.manifest';$config=Join-Path $sourceRoot 'CodexRemote.TrayHost.exe.config';$icon=Join-Path $repo 'assets\codexremote-fix\codexremote-fix.ico'
    foreach($required in @($manifest,$config,$icon)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw 'CCOD_TRAYHOST_SOURCE_MISSING'}}
    $sources=@(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cs' -File|Sort-Object Name)
    if($sources.Count -lt 10){throw 'CCOD_TRAYHOST_SOURCE_INCOMPLETE'}
    $sourceRecords=@($sources|ForEach-Object{[ordered]@{name=$_.Name;sha256=(Get-CcodTrayHostHash $_.FullName)}})
    Import-Module (Join-Path $repo 'build\TrayHostReferencePack.psm1') -Force
    $reference=Resolve-CcodTrayHostReferencePack -LockPath (Join-Path $repo 'build\trayhost-packages.lock.json') -CacheRoot (Join-Path $env:TEMP 'ccod-trayhost-reference-pack')
    $compiler=Get-CcodTrayHostCompiler
    $work=Join-Path ([IO.Path]::GetDirectoryName($out)) ('.ccod-trayhost-build-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $work -Force|Out-Null
    try{
        $exe=Join-Path $work 'CodexRemote.TrayHost.exe';$compilerArgs=@('/nologo','/noconfig','/nostdlib+','/target:winexe','/platform:anycpu','/optimize+','/debug-','/checked+','/warn:4','/warnaserror+',('/out:{0}' -f $exe),('/main:Program'),('/win32manifest:{0}' -f $manifest),('/win32icon:{0}' -f $icon))
        foreach($leaf in @('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll')){$compilerArgs+=('/reference:'+ (Join-Path $reference.ReferenceRoot $leaf))}
        $compilerArgs+=@($sources|ForEach-Object FullName)
        & $compiler @compilerArgs
        if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'CCOD_TRAYHOST_COMPILE_FAILED'}
        $configOut=Join-Path $work 'CodexRemote.TrayHost.exe.config';Copy-Item -LiteralPath $config -Destination $configOut -Force
        $stdoutPath=Join-Path $work 'stdout.txt';$stderrPath=Join-Path $work 'stderr.txt'
        $smoke=Start-Process -FilePath $exe -ArgumentList '--headless-smoke' -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if($smoke.ExitCode -ne 0 -or (Get-Item -LiteralPath $stdoutPath).Length -ne 0 -or (Get-Item -LiteralPath $stderrPath).Length -ne 0){throw 'CCOD_TRAYHOST_HEADLESS_SMOKE_FAILED'}
        $provenance=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$Version;gitCommit=$GitCommit;buildTimestampUtc=$BuildTimestampUtc;targetFramework='net48';compiler=[ordered]@{name='csc.exe';sha256=(Get-CcodTrayHostHash $compiler)};referenceRoot='locked-net48';sourceFiles=$sourceRecords;iconSha256=(Get-CcodTrayHostHash $icon);manifestSha256=(Get-CcodTrayHostHash $manifest);configSha256=(Get-CcodTrayHostHash $config);artifactSha256=(Get-CcodTrayHostHash $exe);configArtifactSha256=(Get-CcodTrayHostHash $configOut)}
        $provenancePath=Join-Path $work 'trayhost-build-provenance.json';$provenance|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $provenancePath -Encoding UTF8
        if(Test-Path -LiteralPath $out){Remove-Item -LiteralPath $out -Recurse -Force}
        New-Item -ItemType Directory -Path $out -Force|Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $out 'CodexRemote.TrayHost.exe') -Force
        Copy-Item -LiteralPath $configOut -Destination (Join-Path $out 'CodexRemote.TrayHost.exe.config') -Force
        Copy-Item -LiteralPath $provenancePath -Destination (Join-Path $out 'trayhost-build-provenance.json') -Force
        return [pscustomobject][ordered]@{ArtifactDirectory=$out;Executable=Join-Path $out 'CodexRemote.TrayHost.exe';Provenance=Join-Path $out 'trayhost-build-provenance.json';Version=$Version;Sha256=(Get-CcodTrayHostHash (Join-Path $out 'CodexRemote.TrayHost.exe'))}
    }finally{if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}}
}

function Test-CcodTrayHostArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$ArtifactDirectory,[string]$ExpectedGitCommit)
    $repo=[IO.Path]::GetFullPath($RepositoryRoot);$out=[IO.Path]::GetFullPath($ArtifactDirectory);Test-CcodTrayHostOutputDirectory $out
    $exe=Join-Path $out 'CodexRemote.TrayHost.exe';$config=Join-Path $out 'CodexRemote.TrayHost.exe.config';$provenancePath=Join-Path $out 'trayhost-build-provenance.json'
    foreach($path in @($exe,$config,$provenancePath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'CCOD_TRAYHOST_ARTIFACT_MISSING'}}
    $provenance=Get-Content -LiteralPath $provenancePath -Raw|ConvertFrom-Json
    $commit=$provenance.PSObject.Properties['gitCommit'];$timestamp=$provenance.PSObject.Properties['buildTimestampUtc']
    if([int]$provenance.schemaVersion -ne 1 -or [string]$provenance.version -cne $Version -or [string]$provenance.targetFramework -cne 'net48' -or $null -eq $commit -or $null -eq $timestamp -or $commit.Value -isnot [string] -or $commit.Value -cnotmatch '^[0-9a-f]{40}$' -or $timestamp.Value -isnot [string] -or -not(Test-CcodTrayHostCanonicalUtc $timestamp.Value) -or (-not [string]::IsNullOrWhiteSpace($ExpectedGitCommit) -and $commit.Value -cne $ExpectedGitCommit)){throw 'CCOD_TRAYHOST_PROVENANCE_INVALID'}
    $icon=Join-Path $repo 'assets\codexremote-fix\codexremote-fix.ico'
    if([string]$provenance.artifactSha256 -cne (Get-CcodTrayHostHash $exe) -or [string]$provenance.configArtifactSha256 -cne (Get-CcodTrayHostHash $config) -or [string]$provenance.iconSha256 -cne (Get-CcodTrayHostHash $icon)){throw 'CCOD_TRAYHOST_ARTIFACT_TAMPERED'}
    $sourceRoot=Join-Path $repo 'src\trayhost';foreach($record in @($provenance.sourceFiles)){ $source=Join-Path $sourceRoot ([string]$record.name);if(-not(Test-Path -LiteralPath $source -PathType Leaf) -or [string]$record.sha256 -cne (Get-CcodTrayHostHash $source)){throw 'CCOD_TRAYHOST_SOURCE_TAMPERED'} }
    return [pscustomobject][ordered]@{Valid=$true;Executable=$exe;Version=$Version;GitCommit=[string]$commit.Value;Sha256=(Get-CcodTrayHostHash $exe)}
}

Export-ModuleMember -Function Invoke-CcodTrayHostBuild,Test-CcodTrayHostArtifact
