# Offline contract data only. Nothing in this fixture may be installed or executed.
function New-CcodLegacyReleaseFixture {
    param([Parameter(Mandatory)][string]$Directory)
    if (@(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop).Count -ne 0) { throw 'legacy fixture directory must be empty' }
    $version='2.5.21';$commit='b'*40;$timestamp='2030-02-03T04:05:06.0000000Z'
    $names=@('CodexRemote-fix-2.5.21-windows-x64.zip','CodexRemote-fix-2.5.21-windows-x64.zip.sha256.txt','CodexRemote-fix-2.5.21-trayhost-provenance.json','CodexRemote-fix-2.5.21-payload-manifest.json','CodexRemote-fix-2.5.21-release-manifest.json','CodexRemote-fix-2.5.21-setup.exe','CodexRemote-fix-2.5.21-setup.exe.sha256.txt','CodexRemote-fix-2.5.21-setup-release-manifest.json')
    $work=Join-Path ([IO.Path]::GetTempPath()) ('ccod-legacy-contract-'+[guid]::NewGuid().ToString('N'))
    $utf8=[Text.UTF8Encoding]::new($false)
    try {
        [IO.Directory]::CreateDirectory((Join-Path $work 'payload'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $work 'CodexRemote-fix.exe'),'inert legacy launcher fixture',$utf8)
        [IO.File]::WriteAllText((Join-Path $work 'CodexRemote-fix.exe.config'),'<configuration/>',$utf8)
        [IO.File]::WriteAllText((Join-Path $work 'Install-CodexRemote-fix.ps1'),'# inert legacy installer fixture',$utf8)
        $payloadFile=Join-Path $work 'payload/fixture.txt'
        [IO.File]::WriteAllText($payloadFile,'legacy payload fixture',$utf8)
        $payload=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;files=@([ordered]@{path='fixture.txt';length=[long](Get-Item $payloadFile).Length;sha256=Get-CcodTestFileSha256 $payloadFile})}
        $payloadJson=$payload|ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $work 'payload-manifest.json'),$payloadJson,$utf8)
        [IO.File]::WriteAllText((Join-Path $Directory $names[3]),$payloadJson,$utf8)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($work,(Join-Path $Directory $names[0]))
        [IO.File]::WriteAllText((Join-Path $Directory $names[1]),((Get-CcodTestFileSha256 (Join-Path $Directory $names[0]))+' *'+$names[0]),$utf8)
        $tray=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;targetFramework='net48';compiler=[ordered]@{name='csc.exe';sha256=('1'*64)};referenceRoot='locked-net48';sourceFiles=@([ordered]@{name='AssemblyInfo.cs';sha256=('2'*64)});iconSha256=('3'*64);manifestSha256=('4'*64);configSha256=('5'*64);artifactSha256=Get-CcodTestFileSha256 (Join-Path $work 'CodexRemote-fix.exe');configArtifactSha256=Get-CcodTestFileSha256 (Join-Path $work 'CodexRemote-fix.exe.config')}
        [IO.File]::WriteAllText((Join-Path $Directory $names[2]),($tray|ConvertTo-Json -Depth 8),$utf8)
        $portableAssets=@(foreach($name in $names[0..3]){[ordered]@{name=$name;sha256=Get-CcodTestFileSha256 (Join-Path $Directory $name)}})
        $portableAssets+=@(foreach($name in @('CodexRemote-fix.exe','CodexRemote-fix.exe.config')){[ordered]@{name=$name;sha256=Get-CcodTestFileSha256 (Join-Path $work $name)}})
        $portable=[ordered]@{schemaVersion=2;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;distribution='portable-zip';assets=$portableAssets}
        [IO.File]::WriteAllText((Join-Path $Directory $names[4]),($portable|ConvertTo-Json -Depth 8),$utf8)
        [IO.File]::WriteAllText((Join-Path $Directory $names[5]),'inert legacy setup fixture',$utf8)
        [IO.File]::WriteAllText((Join-Path $Directory $names[6]),((Get-CcodTestFileSha256 (Join-Path $Directory $names[5]))+' *'+$names[5]),$utf8)
        $setup=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;assets=@(foreach($name in @($names[5],$names[6],$names[2])){[ordered]@{name=$name;sha256=Get-CcodTestFileSha256 (Join-Path $Directory $name)}})}
        [IO.File]::WriteAllText((Join-Path $Directory $names[7]),($setup|ConvertTo-Json -Depth 8),$utf8)
        return [pscustomobject]@{Names=$names;GitCommit=$commit;SetupSha256=Get-CcodTestFileSha256 (Join-Path $Directory $names[5]);ManifestSha256=Get-CcodTestFileSha256 (Join-Path $Directory $names[7])}
    } finally {if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}}
}
