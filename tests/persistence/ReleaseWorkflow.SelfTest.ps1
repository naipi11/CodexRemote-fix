$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$defenderPath = Join-Path $repositoryRoot 'tools\Test-ReleaseDefender.ps1'
$assetContractPath = Join-Path $repositoryRoot 'tools\ReleaseAssetContract.psm1'

function Invoke-CcodTask5Test([string]$Id,[string]$Name,[scriptblock]$Action){if(-not[string]::IsNullOrWhiteSpace($env:CCOD_TASK5_RED_CASE)-and$env:CCOD_TASK5_RED_CASE-cne$Id){return};Invoke-CcodTest $Name $Action}

function ConvertFrom-CcodWorkflowScalar {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $scalar = $Value.Trim()
    if ($scalar.Length -ge 2 -and (($scalar[0] -ceq '"' -and $scalar[$scalar.Length - 1] -ceq '"') -or ($scalar[0] -ceq "'" -and $scalar[$scalar.Length - 1] -ceq "'"))) {
        return $scalar.Substring(1, $scalar.Length - 2)
    }
    return $scalar
}

function Get-CcodWorkflowStructure {
    param([Parameter(Mandatory)][string]$Path)
    $jobs = [Collections.Generic.List[object]]::new()
    $currentJob = $null
    $currentStep = $null
    $inJobs = $false
    $inSteps = $false
    $runBlock = $false
    $runLines = [Collections.Generic.List[string]]::new()
    $lines = [IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false))
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]
        if ($runBlock) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                $runLines.Add('')
                continue
            }
            if ($line -cmatch '^ {10,}') {
                $runLines.Add($line.Substring(10))
                continue
            }
            $currentStep.Run = $runLines -join "`n"
            $runLines.Clear()
            $runBlock = $false
        }
        if (-not $inJobs) {
            if ($line -cmatch '^jobs:\s*(?:#.*)?$') { $inJobs = $true }
            continue
        }
        if ($line -cmatch '^  (?<name>[A-Za-z0-9_-]+):\s*(?:#.*)?$') {
            $currentJob = [pscustomobject]@{ Name = $Matches.name; Steps = [Collections.Generic.List[object]]::new() }
            $jobs.Add($currentJob)
            $currentStep = $null
            $inSteps = $false
            continue
        }
        if ($null -eq $currentJob) { continue }
        if ($line -cmatch '^    steps:\s*(?:#.*)?$') {
            $inSteps = $true
            continue
        }
        if (-not $inSteps) { continue }
        if ($line -cmatch '^      -(?:\s+(?<key>[A-Za-z][A-Za-z0-9_-]*):\s*(?<value>.*))?\s*$') {
            $currentStep = [pscustomobject]@{ Name = ''; Shell = ''; Run = ''; If = ''; ContinueOnError = '' }
            $currentJob.Steps.Add($currentStep)
            $key = [string]$Matches.key
            $value = [string]$Matches.value
            if ($key -in @('name', 'shell', 'run', 'if', 'continue-on-error')) {
                if ($key -ceq 'run' -and $value.Trim() -in @('|', '|-', '|+')) {
                    $runBlock = $true
                    $runLines.Clear()
                } else {
                    $property = switch ($key) {
                        'name' { 'Name' }
                        'shell' { 'Shell' }
                        'run' { 'Run' }
                        'if' { 'If' }
                        'continue-on-error' { 'ContinueOnError' }
                    }
                    $currentStep.$property = ConvertFrom-CcodWorkflowScalar $value
                }
            }
            continue
        }
        if ($null -eq $currentStep) { continue }
        if ($line -cmatch '^        (?<key>name|shell|run|if|continue-on-error):\s*(?<value>.*)$') {
            $key = $Matches.key
            $value = $Matches.value.Trim()
            if ($key -ceq 'run' -and $value -in @('|', '|-', '|+')) {
                $runBlock = $true
                $runLines.Clear()
            } else {
                $property = switch ($key) {
                    'name' { 'Name' }
                    'shell' { 'Shell' }
                    'run' { 'Run' }
                    'if' { 'If' }
                    'continue-on-error' { 'ContinueOnError' }
                }
                $currentStep.$property = ConvertFrom-CcodWorkflowScalar $value
            }
        }
    }
    if ($runBlock) { $currentStep.Run = $runLines -join "`n" }
    return [pscustomobject]@{ Jobs = @($jobs) }
}

function Test-CcodWorkflowStepInvokesBuild {
    param([Parameter(Mandatory)]$Step)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([string]$Step.Run, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw 'CCOD_RELEASE_TRACE_GATE_INVALID' }
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($command in $commands) {
        $commandName = [string]$command.GetCommandName()
        $elements = @($command.CommandElements | ForEach-Object { $_.Extent.Text })
        if ($commandName.Replace('\', '/') -ceq './build/build.ps1' -and $elements -ccontains '-Version') { return $true }
    }
    return $false
}

function Test-CcodWorkflowStepInvokesProductionTrace {
    param([Parameter(Mandatory)]$Step)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([string]$Step.Run, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw 'CCOD_RELEASE_TRACE_GATE_INVALID' }
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($command in $commands) {
        $commandName = [string]$command.GetCommandName()
        $elements = @($command.CommandElements | ForEach-Object { $_.Extent.Text })
        if ($commandName.Replace('\', '/') -ceq './tests/trayhost/Invoke-TrayHostSelfTest.ps1' -and $elements -ccontains '-ProductionTraceOnly') { return $true }
    }
    return $false
}

function Assert-CcodAuthenticatedTraceWorkflowContract {
    param(
        [Parameter(Mandatory)][string]$CiPath,
        [Parameter(Mandatory)][string]$ReleasePath
    )
    $traceName = 'Run authenticated TrayHost production trace'
    $traceRun = './tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly'
    foreach ($target in @(
        [pscustomobject]@{ Path = $CiPath; Job = 'validate'; RequireBuildOrder = $false },
        [pscustomobject]@{ Path = $ReleasePath; Job = 'build'; RequireBuildOrder = $true }
    )) {
        $workflow = Get-CcodWorkflowStructure -Path $target.Path
        $jobs = @($workflow.Jobs | Where-Object { $_.Name -ceq $target.Job })
        if ($jobs.Count -ne 1) { throw 'CCOD_RELEASE_TRACE_GATE_INVALID' }
        $allTraceSteps = @($workflow.Jobs | ForEach-Object { @($_.Steps) } | Where-Object { $_.Name -ceq $traceName })
        $allTraceInvocationSteps = @($workflow.Jobs | ForEach-Object { @($_.Steps) } | Where-Object { Test-CcodWorkflowStepInvokesProductionTrace -Step $_ })
        $traceSteps = @($jobs[0].Steps | Where-Object { $_.Name -ceq $traceName })
        if ($allTraceSteps.Count -ne 1 -or $allTraceInvocationSteps.Count -ne 1 -or $traceSteps.Count -ne 1 -or $traceSteps[0].Shell -cne 'pwsh' -or $traceSteps[0].Run -cne $traceRun -or -not [string]::IsNullOrEmpty([string]$traceSteps[0].If) -or -not [string]::IsNullOrEmpty([string]$traceSteps[0].ContinueOnError)) {
            throw 'CCOD_RELEASE_TRACE_GATE_INVALID'
        }
        if ($target.RequireBuildOrder) {
            $buildIndexes = [Collections.Generic.List[int]]::new()
            for ($stepIndex = 0; $stepIndex -lt $jobs[0].Steps.Count; $stepIndex++) {
                if (Test-CcodWorkflowStepInvokesBuild -Step $jobs[0].Steps[$stepIndex]) { $buildIndexes.Add($stepIndex) }
            }
            $traceIndex = $jobs[0].Steps.IndexOf($traceSteps[0])
            if ($buildIndexes.Count -ne 1 -or $traceIndex -lt 0 -or $traceIndex -ge $buildIndexes[0]) { throw 'CCOD_RELEASE_TRACE_GATE_INVALID' }
        }
    }
}

function New-CcodReleaseFixture {
    $root = Join-Path $env:TEMP ('ccod-release-workflow-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($root)
    $installer = Join-Path $root 'CodexRemote-fix-2.5.0-setup.exe'
    $commit = 'a' * 40
    $payloadInput = Join-Path $root 'CodexRemote-fix-2.5.0-setup-payload-manifest.json'
    $inventoryInput = Join-Path $root 'CodexRemote-fix-2.5.0-setup-destination-inventory.iss'
    $payloadInputRecord = [ordered]@{schemaVersion=1;projectVersion='2.5.0';files=@([ordered]@{path='package.json';length=[int64]1;sha256=('d'*64)})}
    [IO.File]::WriteAllText($payloadInput,($payloadInputRecord|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($inventoryInput,"procedure AddCcodExpectedSetupDirectories(Directories: TStrings);`r`nbegin`r`nend;`r`n",[Text.UTF8Encoding]::new($false))
    $payloadHash = Get-CcodTestFileSha256 -Path $payloadInput
    $typeName = 'SetupFixture' + [guid]::NewGuid().ToString('N')
    $setupSource = @"
using System.Reflection;
[assembly: AssemblyVersion("2.5.0.0")]
[assembly: AssemblyFileVersion("2.5.0.0")]
[assembly: AssemblyInformationalVersion("2.5.0.0")]
[assembly: AssemblyProduct("CodexRemote-fix")]
[assembly: AssemblyTitle("CCODSETUP 2.5.0")]
[assembly: AssemblyDescription("CCODSETUP 2.5.0")]
[assembly: AssemblyCompany("$commit")]
[assembly: AssemblyCopyright("$payloadHash")]
public static class $typeName { public static int Main() { return 0; } }
"@
    Add-Type -TypeDefinition $setupSource -Language CSharp -OutputAssembly $installer -OutputType ConsoleApplication
    $checksum = "$installer.sha256.txt"
    $installerHash = Get-CcodTestFileSha256 -Path $installer
    [IO.File]::WriteAllText($checksum, ("{0} *{1}`r`n" -f $installerHash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    $trayHost = Join-Path $root 'CodexRemote-fix-2.5.0-trayhost-provenance.json'
    [IO.File]::WriteAllText($trayHost, ('{"schemaVersion":1,"product":"CodexRemote-fix","version":"2.5.0","gitCommit":"' + $commit + '","buildTimestampUtc":"2026-08-24T00:00:00.0000000Z"}'), [Text.UTF8Encoding]::new($false))
    $setupProvenance = Join-Path $root 'CodexRemote-fix-2.5.0-setup-provenance.json'
    $setupProvenanceRecord = [ordered]@{
        schemaVersion=1;product='CodexRemote-fix';version='2.5.0';gitCommit=$commit;buildTimestampUtc='2026-08-24T00:00:00.0000000Z'
        payloadManifest=[ordered]@{name='installer-payload.manifest.json';length=[int64](Get-Item -LiteralPath $payloadInput).Length;sha256=$payloadHash;fileCount=1}
        buildInputs=[ordered]@{innoTemplateSha256=$(Get-CcodTestFileSha256 -Path (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'));destinationInventorySha256=$(Get-CcodTestFileSha256 -Path $inventoryInput);compilerSha256='PLACEHOLDER';compilerFileVersion='PLACEHOLDER'}
        peContract=[ordered]@{fileVersion='2.5.0.0';productVersion='2.5.0.0';productName='CodexRemote-fix';fileDescription='CCODSETUP 2.5.0';companyName=$commit;legalCopyright=$payloadHash}
    }
    $iscc = @((Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),(Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
    $setupProvenanceRecord.buildInputs.compilerSha256 = Get-CcodTestFileSha256 -Path $iscc
    $setupProvenanceRecord.buildInputs.compilerFileVersion = [string]([Diagnostics.FileVersionInfo]::GetVersionInfo($iscc).FileVersion)
    [IO.File]::WriteAllText($setupProvenance,(($setupProvenanceRecord|ConvertTo-Json -Depth 8)+"`n"),[Text.UTF8Encoding]::new($false))
    $manifest = Join-Path $root 'CodexRemote-fix-2.5.0-setup-release-manifest.json'
    $assets = @(
        [ordered]@{ name = [IO.Path]::GetFileName($installer); sha256 = $installerHash },
        [ordered]@{ name = [IO.Path]::GetFileName($checksum); sha256 = Get-CcodTestFileSha256 -Path $checksum },
        [ordered]@{ name = [IO.Path]::GetFileName($trayHost); sha256 = Get-CcodTestFileSha256 -Path $trayHost },
        [ordered]@{ name = [IO.Path]::GetFileName($setupProvenance); sha256 = Get-CcodTestFileSha256 -Path $setupProvenance },
        [ordered]@{ name = [IO.Path]::GetFileName($payloadInput); sha256 = Get-CcodTestFileSha256 -Path $payloadInput },
        [ordered]@{ name = [IO.Path]::GetFileName($inventoryInput); sha256 = Get-CcodTestFileSha256 -Path $inventoryInput }
    )
    $record = [ordered]@{
        schemaVersion = 1
        product = 'CodexRemote-fix'
        version = '2.5.0'
        gitCommit = $commit
        buildTimestampUtc = '2026-08-24T00:00:00.0000000Z'
        assets = $assets
    }
    [IO.File]::WriteAllText($manifest, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Root = $root; Installer = $installer; Checksum = $checksum; TrayHost = $trayHost; SetupProvenance = $setupProvenance; PayloadInput=$payloadInput;InventoryInput=$inventoryInput; Manifest = $manifest; PayloadManifestSha256 = $payloadHash }
}

function New-CcodPortableReleaseFixture {
    $root = Join-Path $env:TEMP ('ccod-portable-release-workflow-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $root 'stage'
    $payload = Join-Path $stage 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'Install-CodexRemote-fix.ps1'),'Write-Output portable',[Text.UTF8Encoding]::new($false))
    $launcher = Join-Path $stage 'CodexRemote-fix.exe'
    $launcherConfig = Join-Path $stage 'CodexRemote-fix.exe.config'
    [IO.File]::WriteAllBytes($launcher,[byte[]](3,1,4,1,5,9,2,6))
    [IO.File]::WriteAllText($launcherConfig,'<configuration/>',[Text.UTF8Encoding]::new($false))
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
        [ordered]@{name=[IO.Path]::GetFileName($payloadAsset);sha256=Get-CcodTestFileSha256 -Path $payloadAsset},
        [ordered]@{name='CodexRemote-fix.exe';sha256=Get-CcodTestFileSha256 -Path $launcher},
        [ordered]@{name='CodexRemote-fix.exe.config';sha256=Get-CcodTestFileSha256 -Path $launcherConfig}
    )
    $release = [ordered]@{schemaVersion=2;product='CodexRemote-fix';version='2.5.6';gitCommit=$commit;buildTimestampUtc=$timestamp;distribution='portable-zip';assets=$assets}
    [IO.File]::WriteAllText($manifest,($release | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$root;Bundle=$bundle;Checksum=$checksum;PayloadManifest=$payloadAsset;Manifest=$manifest}
}

function Get-CcodTask5ExpectedAssetNames([string]$Version='2.5.22'){
    @(
        "CodexRemote-fix-$Version-windows-x64.zip",
        "CodexRemote-fix-$Version-windows-x64.zip.sha256.txt",
        "CodexRemote-fix-$Version-trayhost-provenance.json",
        "CodexRemote-fix-$Version-payload-manifest.json",
        "CodexRemote-fix-$Version-release-manifest.json",
        "CodexRemote-fix-$Version-setup.exe",
        "CodexRemote-fix-$Version-setup.exe.sha256.txt",
        "CodexRemote-fix-$Version-setup-provenance.json",
        "CodexRemote-fix-$Version-setup-payload-manifest.json",
        "CodexRemote-fix-$Version-setup-destination-inventory.iss",
        "CodexRemote-fix-$Version-setup-release-manifest.json"
    )
}

function New-CcodTask5ExactAssetFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-'+[guid]::NewGuid().ToString('N'));$outside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-outside-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null;[IO.Directory]::CreateDirectory($outside)|Out-Null
    $version='2.5.22';$commit='c'*40;$timestamp='2030-02-03T04:05:06.0000000Z';$names=Get-CcodTask5ExpectedAssetNames $version
    $stage=Join-Path $root '.stage';$payload=Join-Path $stage 'payload';[IO.Directory]::CreateDirectory($payload)|Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'Install-CodexRemote-fix.ps1'),'Write-Output portable',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllBytes((Join-Path $stage 'CodexRemote-fix.exe'),[byte[]](1,2,3,4));[IO.File]::WriteAllText((Join-Path $stage 'CodexRemote-fix.exe.config'),'<configuration/>',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $payload 'hello.txt'),'payload',[Text.UTF8Encoding]::new($false))
    $payloadFile=Join-Path $payload 'hello.txt';$payloadRecord=[ordered]@{path='hello.txt';length=[int64](Get-Item $payloadFile).Length;sha256=Get-CcodTestFileSha256 $payloadFile};$payloadManifest=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;files=@($payloadRecord)}
    [IO.File]::WriteAllText((Join-Path $stage 'payload-manifest.json'),($payloadManifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop;[IO.Compression.ZipFile]::CreateFromDirectory($stage,(Join-Path $root $names[0]),[IO.Compression.CompressionLevel]::Optimal,$false);Remove-Item -LiteralPath $stage -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $root $names[1]),((Get-CcodTestFileSha256 (Join-Path $root $names[0]))+' *'+$names[0]),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root $names[2]),([ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root $names[3]),($payloadManifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root $names[5]),'setup-bytes',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $root $names[6]),((Get-CcodTestFileSha256 (Join-Path $root $names[5]))+' *'+$names[5]),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root $names[7]),([ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;payloadManifest=[ordered]@{name='installer-payload.manifest.json';sha256=('d'*64)}}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root $names[8]),([ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;payloadManifest=[ordered]@{name='installer-payload.manifest.json';sha256=('d'*64)};files=@([ordered]@{path='package.json';length=[int64]1;sha256=('e'*64)})}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $root $names[9]),"procedure AddCcodExpectedSetupDirectories(Directories: TStrings);`r`nbegin`r`nend;`r`n",[Text.UTF8Encoding]::new($false))
    $portableAssets=@([ordered]@{name=$names[0];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[0])},[ordered]@{name=$names[1];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[1])},[ordered]@{name=$names[2];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[2])},[ordered]@{name=$names[3];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[3])},[ordered]@{name='CodexRemote-fix.exe';sha256=('1'*64)},[ordered]@{name='CodexRemote-fix.exe.config';sha256=('2'*64)})
    [IO.File]::WriteAllText((Join-Path $root $names[4]),([ordered]@{schemaVersion=2;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;distribution='portable-zip';assets=$portableAssets}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $setupAssets=@([ordered]@{name=$names[5];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[5])},[ordered]@{name=$names[6];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[6])},[ordered]@{name=$names[2];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[2])},[ordered]@{name=$names[7];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[7])},[ordered]@{name=$names[8];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[8])},[ordered]@{name=$names[9];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[9])})
    [IO.File]::WriteAllText((Join-Path $root $names[10]),([ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;assets=$setupAssets}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Root=$root;OriginalRoot=$root;Outside=$outside;Names=$names;Version=$version;GitCommit=$commit;Timestamp=$timestamp}
}

function Remove-CcodTask5ExactAssetFixture($Fixture){foreach($path in @($Fixture.Root,$Fixture.OriginalRoot,$Fixture.Outside)){if([string]::IsNullOrWhiteSpace([string]$path)){continue};$full=[IO.Path]::GetFullPath([string]$path);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';if(-not$full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'refusing non-temp asset fixture cleanup'};if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}}}

function New-CcodTask5DefenderStatus {
    [pscustomobject][ordered]@{AMServiceEnabled=$true;AntivirusEnabled=$true;RealTimeProtectionEnabled=$true;AMProductVersion='4.18.26070.1';AMEngineVersion='1.1.26070.1';AntivirusSignatureVersion='1.999.1.0';AntivirusSignatureLastUpdated=[datetime]::Parse('2030-02-03T02:05:06Z').ToUniversalTime()}
}

function New-CcodTask5DefenderAdapterFixture {
    param($Status=(New-CcodTask5DefenderStatus),[datetime]$Started=([datetime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()),$Completed=([datetime]::Parse('2030-02-03T04:05:07Z').ToUniversalTime()),[switch]$ScanThrows,[switch]$Detects,[switch]$WriteThrows)
    $state=[pscustomobject]@{Capture=$null;Clock=0;Threat=0;Calls=[Collections.Generic.List[string]]::new()}
    $adapters=@{
        GetFileSha256={param($Path)$state.Calls.Add('Hash');Get-CcodTestFileSha256 $Path}.GetNewClosure()
        GetDefenderStatus={ $state.Calls.Add('Status');$Status }.GetNewClosure()
        StartCustomScan={param($Path)$state.Calls.Add('Scan');if($ScanThrows){throw 'fixture scan failure'}}.GetNewClosure()
        GetThreatDetections={$state.Calls.Add('Threat');$state.Threat++;if($Detects-and$state.Threat-gt1){@([pscustomobject]@{ThreatID=99;InitialDetectionTime='2030-02-03T04:05:06.0000000Z';Resources=@('redacted')})}else{@()}}.GetNewClosure()
        GetUtcNow={$state.Calls.Add('Clock');$state.Clock++;if($state.Clock-eq1){$Started}else{$Completed}}.GetNewClosure()
        WriteReceipt={param($Path,$Receipt)$state.Calls.Add('Write');if($WriteThrows){throw 'fixture evidence write failure'};$state.Capture=(($Receipt|ConvertTo-Json -Depth 12 -Compress)|ConvertFrom-Json);$Path}.GetNewClosure()
    }
    [pscustomobject]@{Adapters=$adapters;State=$state}
}

function New-CcodTask5WorkflowIdentity([string]$Commit=('a'*40)){
    [pscustomobject][ordered]@{provider='GitHubActions';repository='naipi11/CodexRemote-fix';runId=[uint64]123;runAttempt=[uint64]2;artifactId=[uint64]456;artifactName='CodexRemote-fix portable bundle';artifactDigest=('sha256:'+('9'*64));gitCommit=$Commit}
}

function New-CcodTask5DefenderReceipt {
    param([ValidateSet('Setup','PortableZip')][string]$AssetType='Setup',[string]$Version='2.5.22',[string]$Commit=('c'*40),[ValidateSet('InternetDownload','TrustedWorkflowArtifact')][string]$Origin='InternetDownload')
    $names=Get-CcodTask5ExpectedAssetNames $Version;$setup=$AssetType-ceq'Setup'
    [pscustomobject][ordered]@{schemaVersion=2;assetType=$AssetType;assetName=$(if($setup){$names[5]}else{$names[0]});assetSha256=$(if($setup){'5'*64}else{'0'*64});checksumName=$(if($setup){$names[6]}else{$names[1]});checksumSha256=$(if($setup){'6'*64}else{'1'*64});manifestName=$(if($setup){$names[10]}else{$names[4]});manifestSha256=$(if($setup){'a'*64}else{'4'*64});version=$Version;gitCommit=$Commit;origin=$Origin;workflowArtifactIdentity=$(if($Origin-ceq'TrustedWorkflowArtifact'){New-CcodTask5WorkflowIdentity $Commit}else{$null});zoneId=$(if($Origin-ceq'InternetDownload'){3}else{$null});defenderServiceEnabled=$true;antivirusEnabled=$true;realTimeProtectionEnabled=$true;defenderPlatformVersion='4.18.26070.1';defenderEngineVersion='1.1.26070.1';signatureVersion='1.999.1.0';signatureUpdatedAtUtc='2030-02-03T02:05:06.0000000Z';scanStartedAtUtc='2030-02-03T04:05:06.0000000Z';scanCompletedAtUtc='2030-02-03T04:05:07.0000000Z';detectionCount=0;outcome='Completed';errorCode=$null}
}

function Get-CcodTask5PromotionReceiptNames([string]$Version='2.5.22'){
    @("CodexRemote-fix-$Version-setup.internet-download.defender.json","CodexRemote-fix-$Version-windows-x64.internet-download.defender.json")
}

function Write-CcodTask5Json {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 12)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function New-CcodTask5PromotionFixture {
    param([Parameter(Mandatory)]$AssetFixture)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-promotion-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $names=Get-CcodTask5PromotionReceiptNames
    $setup=New-CcodTask5DefenderReceipt -AssetType Setup
    $portable=New-CcodTask5DefenderReceipt -AssetType PortableZip
    $setup.assetSha256=Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[5]);$setup.checksumSha256=Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[6]);$setup.manifestSha256=Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[10])
    $portable.assetSha256=Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[0]);$portable.checksumSha256=Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[1]);$portable.manifestSha256=Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[4])
    Write-CcodTask5Json -Path (Join-Path $root $names[0]) -Value $setup
    Write-CcodTask5Json -Path (Join-Path $root $names[1]) -Value $portable
    [pscustomobject]@{Root=$root;Names=$names;Setup=$setup;Portable=$portable;Commit=('c'*40);Version='2.5.22'}
}

function Get-CcodReadOnlyProductTreeSnapshot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaximumEntries=8192,
        [long]$MaximumFileBytes=268435456,
        [long]$MaximumTotalBytes=1073741824
    )
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if([IO.File]::Exists($full)){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
    if(-not[IO.Directory]::Exists($full)){
        return [pscustomobject][ordered]@{root=$full;exists=$false;rootAttributes=$null;rootCreationTimeUtc=$null;rootLastWriteTimeUtc=$null;entryCount=0;totalBytes=[long]0;records=@()}
    }
    $rootItem=Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if(-not$rootItem.PSIsContainer-or($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
    $prefix=$full+'\';$pending=[Collections.Generic.Stack[string]]::new();$pending.Push($full);$records=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$total=[long]0
    while($pending.Count-gt0){
        $directory=$pending.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)){
            if($records.Count-ge$MaximumEntries){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
            $path=[IO.Path]::GetFullPath($item.FullName)
            if(-not$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
            $relative=$path.Substring($prefix.Length).Replace('\','/')
            if([string]::IsNullOrWhiteSpace($relative)-or-not$seen.Add($relative)){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
            if($item.PSIsContainer){
                $records.Add([pscustomobject][ordered]@{path=$relative;kind='directory';attributes=[int]$item.Attributes;creationTimeUtc=$item.CreationTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);lastWriteTimeUtc=$item.LastWriteTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);length=$null;sha256=$null})
                $pending.Push($path)
            }else{
                $length=[long]$item.Length
                if($length-lt0-or$length-gt$MaximumFileBytes-or$total-gt($MaximumTotalBytes-$length)){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
                $total+=$length
                try{$streams=@(Get-Item -LiteralPath $path -Stream * -ErrorAction Stop|Where-Object{[string]$_.Stream-cnotin@(':$DATA','::$DATA','$DATA')})}catch{throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
                if($streams.Count-ne0){throw 'CCOD_TEST_PRODUCT_SNAPSHOT_UNSAFE'}
                $records.Add([pscustomobject][ordered]@{path=$relative;kind='file';attributes=[int]$item.Attributes;creationTimeUtc=$item.CreationTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);lastWriteTimeUtc=$item.LastWriteTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);length=$length;sha256=Get-CcodTestFileSha256 -Path $path})
            }
        }
    }
    $comparison=[System.Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)};$records.Sort($comparison)
    return [pscustomobject][ordered]@{root=$full;exists=$true;rootAttributes=[int]$rootItem.Attributes;rootCreationTimeUtc=$rootItem.CreationTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);rootLastWriteTimeUtc=$rootItem.LastWriteTimeUtc.ToString('o',[Globalization.CultureInfo]::InvariantCulture);entryCount=$records.Count;totalBytes=$total;records=@($records)}
}

Invoke-CcodTask5Test 'assets' 'release asset contract owns the exact ordered eleven-name set and rejects every mutation' {
    Assert-CcodTrue (Test-Path -LiteralPath $assetContractPath -PathType Leaf) 'central release asset contract module exists'
    $assetModule=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    try{
        $expected=Get-CcodTask5ExpectedAssetNames '2.5.22';$actual=@(Get-CcodExpectedReleaseAssetNames -Version '2.5.22')
        Assert-CcodEqual ($expected-join'|') ($actual-join'|') 'asset contract returns the literal ordered eleven-name set'
        $baseline=New-CcodTask5ExactAssetFixture
        try{$validated=Test-CcodExactReleaseAssetSet -AssetDirectory $baseline.Root -Version $baseline.Version;Assert-CcodEqual $baseline.GitCommit ([string]$validated.GitCommit) 'exact set returns the common 40-hex commit';Assert-CcodEqual $baseline.Timestamp ([string]$validated.BuildTimestampUtc) 'exact set returns the common timestamp';Assert-CcodEqual ($expected-join'|') ((@($validated.Assets.name))-join'|') 'exact set returns all public hashes in contract order'}finally{Remove-CcodTask5ExactAssetFixture $baseline}
        foreach($missing in $expected){$fixture=New-CcodTask5ExactAssetFixture;try{Remove-Item -LiteralPath (Join-Path $fixture.Root $missing) -Force;Assert-CcodThrows {Test-CcodExactReleaseAssetSet -AssetDirectory $fixture.Root -Version $fixture.Version|Out-Null} 'CCOD_RELEASE_ASSET_SET_INVALID'}finally{Remove-CcodTask5ExactAssetFixture $fixture}}
        foreach($mutation in @('Extra','CaseVaried','Directory','Reparse','UnsafeAncestry','NoncanonicalRoot','DuplicateTopProperty','DuplicateNestedProperty','DuplicateEscapedProperty','DuplicateManifest','ManifestOrder','CommitMismatch','TimestampMismatch','SharedProvenanceMismatch')){
            $fixture=New-CcodTask5ExactAssetFixture
            try{
                switch($mutation){
                    'Extra'{[IO.File]::WriteAllText((Join-Path $fixture.Root 'unexpected.txt'),'x',[Text.UTF8Encoding]::new($false))}
                    'CaseVaried'{$source=Join-Path $fixture.Root $fixture.Names[0];$temporary=$source+'.case';Move-Item -LiteralPath $source -Destination $temporary;Move-Item -LiteralPath $temporary -Destination (Join-Path $fixture.Root $fixture.Names[0].ToUpperInvariant())}
                    'Directory'{Remove-Item -LiteralPath (Join-Path $fixture.Root $fixture.Names[3]) -Force;[IO.Directory]::CreateDirectory((Join-Path $fixture.Root $fixture.Names[3]))|Out-Null}
                    'Reparse'{Remove-Item -LiteralPath (Join-Path $fixture.Root $fixture.Names[3]) -Force;$target=Join-Path $fixture.Outside 'target';[IO.Directory]::CreateDirectory($target)|Out-Null;$previous=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$out=&cmd.exe /d /c mklink /J (Join-Path $fixture.Root $fixture.Names[3]) $target 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$previous};if($code-ne0){throw "junction fixture failed: $($out-join' ')"}}
                    'UnsafeAncestry'{$parent=Join-Path $fixture.Outside 'parent';[IO.Directory]::CreateDirectory($parent)|Out-Null;$link=Join-Path $parent 'assets';$previous=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$out=&cmd.exe /d /c mklink /J $link $fixture.Root 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$previous};if($code-ne0){throw "ancestry fixture failed: $($out-join' ')"};$fixture.Root=$link}
                    'NoncanonicalRoot'{$fixture.Root=[string]$fixture.Root+'\.'}
                    'DuplicateTopProperty'{$manifestPath=Join-Path $fixture.Root $fixture.Names[4];$raw=[IO.File]::ReadAllText($manifestPath);$raw=[regex]::Replace($raw,'"schemaVersion"\s*:\s*2','"schemaVersion": 2, "schemaVersion": 2',1);[IO.File]::WriteAllText($manifestPath,$raw,[Text.UTF8Encoding]::new($false))}
                    'DuplicateNestedProperty'{$manifestPath=Join-Path $fixture.Root $fixture.Names[4];$raw=[IO.File]::ReadAllText($manifestPath);$raw=[regex]::Replace($raw,'"name"\s*:\s*"([^"]+)"','"name": "$1", "name": "$1"',1);[IO.File]::WriteAllText($manifestPath,$raw,[Text.UTF8Encoding]::new($false))}
                    'DuplicateEscapedProperty'{$manifestPath=Join-Path $fixture.Root $fixture.Names[4];$raw=[IO.File]::ReadAllText($manifestPath);$raw=[regex]::Replace($raw,'"gitCommit"\s*:\s*"([^"]+)"','"gitCommit": "$1", "\u0067itCommit": "$1"',1);[IO.File]::WriteAllText($manifestPath,$raw,[Text.UTF8Encoding]::new($false))}
                    default{$manifestPath=Join-Path $fixture.Root $fixture.Names[4];$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json;if($mutation-ceq'DuplicateManifest'){$manifest.assets=@($manifest.assets)+@($manifest.assets[0])}elseif($mutation-ceq'ManifestOrder'){$manifest.assets=@($manifest.assets[1],$manifest.assets[0])+@($manifest.assets|Select-Object -Skip 2)}elseif($mutation-ceq'CommitMismatch'){$manifest.gitCommit='d'*40}elseif($mutation-ceq'TimestampMismatch'){$manifest.buildTimestampUtc='2030-02-03T04:05:07.0000000Z'}else{$entry=@($manifest.assets|Where-Object{$_.name-ceq$fixture.Names[2]})[0];$entry.sha256='f'*64};[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
                }
                Assert-CcodThrows {Test-CcodExactReleaseAssetSet -AssetDirectory $fixture.Root -Version $fixture.Version|Out-Null} 'CCOD_RELEASE_ASSET_SET_INVALID'
            }finally{Remove-CcodTask5ExactAssetFixture $fixture}
        }
    }finally{if($null-ne$assetModule){Remove-Module -Name $assetModule.Name -Force -ErrorAction SilentlyContinue}}
}

Invoke-CcodTask5Test 'promotion' 'promotion requires exactly distinct Setup and ZIP Internet-download Defender receipts' {
    Assert-CcodTrue (Test-Path -LiteralPath $assetContractPath -PathType Leaf) 'central release asset contract module exists for promotion validation'
    $assetModule=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    $assetFixture=$null
    try{
        $assetFixture=New-CcodTask5ExactAssetFixture
        $baseline=New-CcodTask5PromotionFixture -AssetFixture $assetFixture
        try{
            $validated=Test-CcodReleasePromotionEvidence -EvidenceDirectory $baseline.Root -AssetDirectory $assetFixture.Root -Version $baseline.Version -ExpectedGitCommit $baseline.Commit
            Assert-CcodEqual 'Setup,PortableZip' ((@($validated.Receipts.assetType))-join',') 'promotion returns the two distinct official asset types in contract order'
            Assert-CcodTrue (@($validated.Receipts|Where-Object{$_.origin-cne'InternetDownload'-or$_.zoneId-ne3}).Count-eq0) 'promotion returns only actual Internet-download receipts'
        }finally{if(Test-Path $baseline.Root){Remove-Item -LiteralPath $baseline.Root -Recurse -Force}}

        foreach($shape in @('MissingSetup','MissingPortable','Extra','DuplicateSetup','DuplicatePortable','Swapped','ReusedHashes','ForgedTriplet','TrustedSubstitution')){
            $fixture=New-CcodTask5PromotionFixture -AssetFixture $assetFixture
            try{
                $setupPath=Join-Path $fixture.Root $fixture.Names[0];$portablePath=Join-Path $fixture.Root $fixture.Names[1]
                switch($shape){
                    'MissingSetup'{Remove-Item -LiteralPath $setupPath -Force}
                    'MissingPortable'{Remove-Item -LiteralPath $portablePath -Force}
                    'Extra'{Write-CcodTask5Json -Path (Join-Path $fixture.Root 'unexpected.defender.json') -Value $fixture.Setup}
                    'DuplicateSetup'{Write-CcodTask5Json -Path $portablePath -Value $fixture.Setup}
                    'DuplicatePortable'{Write-CcodTask5Json -Path $setupPath -Value $fixture.Portable}
                    'Swapped'{Write-CcodTask5Json -Path $setupPath -Value $fixture.Portable;Write-CcodTask5Json -Path $portablePath -Value $fixture.Setup}
                    'ReusedHashes'{$fixture.Portable.assetSha256=$fixture.Setup.assetSha256;$fixture.Portable.checksumSha256=$fixture.Setup.checksumSha256;$fixture.Portable.manifestSha256=$fixture.Setup.manifestSha256;Write-CcodTask5Json -Path $portablePath -Value $fixture.Portable}
                    'ForgedTriplet'{$fixture.Setup.assetSha256='b'*64;$fixture.Setup.checksumSha256='c'*64;$fixture.Setup.manifestSha256='d'*64;Write-CcodTask5Json -Path $setupPath -Value $fixture.Setup}
                    'TrustedSubstitution'{$fixture.Setup.origin='TrustedWorkflowArtifact';$fixture.Setup.workflowArtifactIdentity=New-CcodTask5WorkflowIdentity $fixture.Commit;$fixture.Setup.zoneId=$null;Write-CcodTask5Json -Path $setupPath -Value $fixture.Setup}
                }
                Assert-CcodThrows {Test-CcodReleasePromotionEvidence -EvidenceDirectory $fixture.Root -AssetDirectory $assetFixture.Root -Version $fixture.Version -ExpectedGitCommit $fixture.Commit|Out-Null} 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
            }finally{if(Test-Path $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force}}
        }

        foreach($field in @('schemaVersion','assetType','assetName','assetSha256','checksumName','checksumSha256','manifestName','manifestSha256','version','gitCommit','origin','workflowArtifactIdentity','zoneId','defenderServiceEnabled','antivirusEnabled','realTimeProtectionEnabled','defenderPlatformVersion','defenderEngineVersion','signatureVersion','signatureUpdatedAtUtc','scanStartedAtUtc','scanCompletedAtUtc','detectionCount','outcome','errorCode')){
            $fixture=New-CcodTask5PromotionFixture -AssetFixture $assetFixture
            try{
                $receipt=$fixture.Setup
                switch($field){
                    'schemaVersion'{$receipt.schemaVersion=1}
                    'assetType'{$receipt.assetType='PortableZip'}
                    'assetName'{$receipt.assetName='foreign.exe'}
                    'assetSha256'{$receipt.assetSha256='z'*64}
                    'checksumName'{$receipt.checksumName='foreign.sha256.txt'}
                    'checksumSha256'{$receipt.checksumSha256='z'*64}
                    'manifestName'{$receipt.manifestName='foreign.json'}
                    'manifestSha256'{$receipt.manifestSha256='z'*64}
                    'version'{$receipt.version='2.5.21'}
                    'gitCommit'{$receipt.gitCommit='b'*40}
                    'origin'{$receipt.origin='TrustedWorkflowArtifact'}
                    'workflowArtifactIdentity'{$receipt.workflowArtifactIdentity=New-CcodTask5WorkflowIdentity $fixture.Commit}
                    'zoneId'{$receipt.zoneId=2}
                    'defenderServiceEnabled'{$receipt.defenderServiceEnabled=$false}
                    'antivirusEnabled'{$receipt.antivirusEnabled=$false}
                    'realTimeProtectionEnabled'{$receipt.realTimeProtectionEnabled=$false}
                    'defenderPlatformVersion'{$receipt.defenderPlatformVersion=''}
                    'defenderEngineVersion'{$receipt.defenderEngineVersion=''}
                    'signatureVersion'{$receipt.signatureVersion=''}
                    'signatureUpdatedAtUtc'{$receipt.signatureUpdatedAtUtc='2030-01-01T00:00:00.0000000Z'}
                    'scanStartedAtUtc'{$receipt.scanStartedAtUtc='not-a-clock'}
                    'scanCompletedAtUtc'{$receipt.scanCompletedAtUtc='2030-02-03T04:05:05.0000000Z'}
                    'detectionCount'{$receipt.detectionCount=1}
                    'outcome'{$receipt.outcome='Failed'}
                    'errorCode'{$receipt.errorCode='CCOD_DEFENDER_SCAN_FAILED'}
                }
                Write-CcodTask5Json -Path (Join-Path $fixture.Root $fixture.Names[0]) -Value $receipt
                Assert-CcodThrows {Test-CcodReleasePromotionEvidence -EvidenceDirectory $fixture.Root -AssetDirectory $assetFixture.Root -Version $fixture.Version -ExpectedGitCommit $fixture.Commit|Out-Null} 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
            }finally{if(Test-Path $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force}}
        }
    }finally{if($null-ne$assetFixture){Remove-CcodTask5ExactAssetFixture $assetFixture};if($null-ne$assetModule){Remove-Module -Name $assetModule.Name -Force -ErrorAction SilentlyContinue}}
}

Invoke-CcodTest 'release defender tool exposes manifest and scan functions without a live scan' {
    Assert-CcodTrue (Test-Path -LiteralPath $defenderPath -PathType Leaf) 'Defender release gate exists'
    . $defenderPath -Library
    Assert-CcodTrue ($null -ne (Get-Command Test-CcodReleaseAssetManifest -ErrorAction SilentlyContinue)) 'release manifest validator is exported for deterministic tests'
    Assert-CcodTrue ($null -ne (Get-Command Invoke-CcodReleaseDefenderCheck -ErrorAction SilentlyContinue)) 'Defender invocation is available'
}

Invoke-CcodTest 'production installer payload generator writes ordered version-bound file records' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-installer-manifest-generator-' + [guid]::NewGuid().ToString('N'))
    try {
        $payload = Join-Path $root 'payload'
        [IO.Directory]::CreateDirectory((Join-Path $payload 'nested')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'z-last.txt'),'z',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $payload 'nested\a-first.txt'),'alpha',[Text.UTF8Encoding]::new($false))
        $manifestPath = Join-Path $root 'installer-payload.manifest.json'
        & (Join-Path $repositoryRoot 'tools\New-InstallerPayloadManifest.ps1') -PayloadRoot $payload -ProjectVersion '2.5.22' -OutputPath $manifestPath | Out-Null
        Assert-CcodTrue (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'production manifest generator writes its requested output'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,projectVersion,files' (@($manifest.PSObject.Properties.Name) -join ',') 'generator writes the canonical manifest field order'
        Assert-CcodEqual '2.5.22' $manifest.projectVersion 'generator binds the requested project version'
        Assert-CcodEqual 'nested/a-first.txt,z-last.txt' (@($manifest.files.path) -join ',') 'generator sorts file records ordinally'
        foreach ($record in $manifest.files) {
            $file = Join-Path $payload ([string]$record.path).Replace('/','\')
            Assert-CcodEqual ([int64](Get-Item -LiteralPath $file).Length) ([int64]$record.length) 'record length binds the file bytes'
            Assert-CcodEqual (Get-CcodTestFileSha256 -Path $file) ([string]$record.sha256) 'record hash binds the file bytes'
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

# Production mutation caught: accepting a ZIP whose entry set or identity no longer matches the manifest bound by Setup.
Invoke-CcodTest 'sealed installer package rejects entry and identity changes before product state exists' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-sealed-installer-package-' + [guid]::NewGuid().ToString('N'))
    $module = $null
    try {
        $payload = Join-Path $root 'payload'
        foreach ($directory in @('src\persistence\modules')) { [IO.Directory]::CreateDirectory((Join-Path $payload $directory)) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $payload 'package.json'),'{"version":"2.5.22"}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $payload 'Install-CodexControlOtherDevices.ps1'),'param()',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $payload 'src\persistence\modules\InstallLifecycle.psm1'),'# lifecycle',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $payload 'src\persistence\modules\RuntimeManifest.psm1'),'# manifest',[Text.UTF8Encoding]::new($false))
        $payloadManifest = Join-Path $root 'installer-payload.manifest.json'
        & (Join-Path $repositoryRoot 'tools\New-InstallerPayloadManifest.ps1') -PayloadRoot $payload -ProjectVersion '2.5.22' -OutputPath $payloadManifest | Out-Null
        $package = Join-Path $root 'installer-package.zip'
        $manifest = Join-Path $root 'installer-package.manifest.json'
        $module = Import-Module (Join-Path $repositoryRoot 'build\InstallerPackage.psm1') -Force -PassThru
        $created = New-CcodInstallerPackage -PayloadRoot $payload -PayloadManifestPath $payloadManifest -Version '2.5.22' -GitCommit ('a' * 40) -OutputPath $package -ManifestOutputPath $manifest
        $validated = Test-CcodInstallerPackage -PackagePath $package -ManifestPath $manifest -ExpectedPackageSha256 $created.PackageSha256 -ExpectedManifestSha256 $created.ManifestSha256 -ExpectedVersion '2.5.22' -ExpectedGitCommit ('a' * 40)
        Assert-CcodEqual $true ([bool]$validated.Valid) 'canonical sealed installer package validates'

        Assert-CcodThrows {
            Test-CcodInstallerPackage -PackagePath $package -ManifestPath $manifest -ExpectedPackageSha256 ('0' * 64) -ExpectedManifestSha256 $created.ManifestSha256 -ExpectedVersion '2.5.22' -ExpectedGitCommit ('a' * 40) | Out-Null
        } 'CCOD_INSTALLER_PACKAGE_HASH_MISMATCH'
        Assert-CcodThrows {
            Test-CcodInstallerPackage -PackagePath $package -ManifestPath $manifest -ExpectedPackageSha256 $created.PackageSha256 -ExpectedManifestSha256 ('0' * 64) -ExpectedVersion '2.5.22' -ExpectedGitCommit ('a' * 40) | Out-Null
        } 'CCOD_INSTALLER_PACKAGE_MANIFEST_HASH_MISMATCH'
        Assert-CcodThrows {
            Test-CcodInstallerPackage -PackagePath $package -ManifestPath $manifest -ExpectedPackageSha256 $created.PackageSha256 -ExpectedManifestSha256 $created.ManifestSha256 -ExpectedVersion '9.9.9' -ExpectedGitCommit ('a' * 40) | Out-Null
        } 'CCOD_INSTALLER_PACKAGE_INVALID'
        Assert-CcodThrows {
            Test-CcodInstallerPackage -PackagePath $package -ManifestPath $manifest -ExpectedPackageSha256 $created.PackageSha256 -ExpectedManifestSha256 $created.ManifestSha256 -ExpectedVersion '2.5.22' -ExpectedGitCommit ('b' * 40) | Out-Null
        } 'CCOD_INSTALLER_PACKAGE_INVALID'

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        foreach ($variant in @(
            [pscustomobject]@{Name='missing';Mutate={param($archive)$archive.GetEntry('package.json').Delete()}},
            [pscustomobject]@{Name='extra';Mutate={param($archive)$entry=$archive.CreateEntry('extra.txt');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('extra')}finally{$writer.Dispose()}}},
            [pscustomobject]@{Name='duplicate';Mutate={param($archive)$entry=$archive.CreateEntry('package.json');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('{}')}finally{$writer.Dispose()}}},
            [pscustomobject]@{Name='unsafe';Mutate={param($archive)$entry=$archive.CreateEntry('../escape.txt');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('escape')}finally{$writer.Dispose()}}},
            [pscustomobject]@{Name='changed';Mutate={param($archive)$archive.GetEntry('package.json').Delete();$entry=$archive.CreateEntry('package.json');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('{"version":"9.9.9"}')}finally{$writer.Dispose()}}}
        )) {
            $variantPath = Join-Path $root ("$($variant.Name).zip")
            [IO.File]::Copy($package,$variantPath,$false)
            $archive = [IO.Compression.ZipFile]::Open($variantPath,[IO.Compression.ZipArchiveMode]::Update)
            try { & $variant.Mutate $archive } finally { $archive.Dispose() }
            $variantHash = Get-CcodTestFileSha256 -Path $variantPath
            Assert-CcodThrows {
                Test-CcodInstallerPackage -PackagePath $variantPath -ManifestPath $manifest -ExpectedPackageSha256 $variantHash -ExpectedManifestSha256 $created.ManifestSha256 -ExpectedVersion '2.5.22' -ExpectedGitCommit ('a' * 40) | Out-Null
            } 'CCOD_INSTALLER_PACKAGE_INVALID'
        }
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $root 'product-state'))) 'all package failures precede product state creation'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

# Production mutation caught: restoring any legacy recursive {app} copy or executing a writable app bootstrap before Ready.
Invoke-CcodTest 'Setup contains only sealed temporary inputs and no pre-Ready app product write' {
    $source = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    Assert-CcodTrue ($source -cmatch '(?m)^CreateAppDir=no\s*$') 'Setup never creates app before Ready'
    Assert-CcodTrue ($source -cmatch '(?m)^Uninstallable=no\s*$') 'Setup never creates an Inno uninstaller before Ready'
    Assert-CcodTrue ($source -cmatch 'InstallerPackageSha256' -and $source -cmatch 'InstallerPackageManifestSha256' -and $source -cmatch 'ActivationBootstrapSha256') 'Setup binds package manifest and bootstrap hashes'
    Assert-CcodTrue ($source -cnotmatch '(?im)^\s*Source:.*DestDir:\s*"\{app\}' -and $source -cnotmatch '(?im)^\[(Icons|Registry|UninstallRun)\]\s*$') 'Setup has no pre-Ready app Files Icons Registry or UninstallRun writes'
    Assert-CcodTrue ($source -cnotmatch 'recursesubdirs|createallsubdirs|Source:\s*"[^"]*\\\*"') 'Setup never recursively extracts an arbitrary payload tree'
    Assert-CcodTrue ($source -cnotmatch '-File\s+"\{app\}\\Activate-CcodRemoteFix\.ps1"') 'Setup never executes activation from writable app'
    $fileLines = @([regex]::Matches($source,'(?im)^\s*Source:\s*"[^\r\n]+$') | ForEach-Object { $_.Value })
    Assert-CcodEqual 4 $fileLines.Count 'Setup embeds exactly package manifest bootstrap and provenance inputs'
    foreach ($line in $fileLines) { Assert-CcodTrue ($line -cmatch 'Flags:\s*dontcopy\s*$') 'every Setup input is private temporary dontcopy data' }
}

Invoke-CcodTest 'production setup template has one inventory marker no external includes and no product destination inventory' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-installer-directory-inventory-' + [guid]::NewGuid().ToString('N'))
    try {
        $payload = Join-Path $root 'payload'
        [IO.Directory]::CreateDirectory((Join-Path $payload 'src\persistence\modules')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'src\persistence\modules\InstallLifecycle.psm1'),'fixture',[Text.UTF8Encoding]::new($false))
        $output = Join-Path $root 'InstallerDestinationInventory.iss'
        $innoPath = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
        $templateLines = @([IO.File]::ReadAllLines($innoPath,[Text.UTF8Encoding]::new($false)))
        $inventoryMarkers = @($templateLines | Where-Object { [string]$_ -ceq '// CCOD_INSTALLER_DESTINATION_INVENTORY' })
        $externalIncludes = @($templateLines | Where-Object { [string]$_ -match '^\s*#\s*(?:include\b|\+)' })
        Assert-CcodEqual 1 $inventoryMarkers.Count 'production template has exactly one destination inventory marker comment'
        Assert-CcodEqual 0 $externalIncludes.Count 'production template has no external include directive'
        & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $innoPath -OutputPath $output | Out-Null
        $inventory = [IO.File]::ReadAllText($output,[Text.UTF8Encoding]::new($false))
        Assert-CcodTrue ($inventory -cmatch '(?s)^procedure AddCcodExpectedSetupDirectories\(Directories: TStrings\);\s*begin\s*end;\s*$') 'sealed Setup produces an explicit empty product destination inventory'
        Assert-CcodTrue ($inventory -cnotmatch 'Directories\.Add') 'no payload directory can be created before Ready'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'production setup destination inventory rejects multiple Files sections' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-installer-multiple-files-sections-' + [guid]::NewGuid().ToString('N'))
    try {
        $payload = Join-Path $root 'payload'
        [IO.Directory]::CreateDirectory($payload) | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'package.json'),'{}',[Text.UTF8Encoding]::new($false))
        $innoPath = Join-Path $root 'MultipleFilesSections.iss'
        $innoSource = @'
[Setup]
AppName=Fixture
AppVersion=1.0.0
DefaultDirName={app}
[Files]
Source: "fixture-a.txt"; DestDir: "{app}\first"; Flags: ignoreversion
[Code]
procedure Fixture();
begin
end;
[Files]
Source: "fixture-b.txt"; DestDir: "{app}\second"; Flags: ignoreversion
'@
        [IO.File]::WriteAllText($innoPath,$innoSource,[Text.UTF8Encoding]::new($false))
        $output = Join-Path $root 'Inventory.iss'
        $failure = $null
        try {
            & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $innoPath -OutputPath $output | Out-Null
        } catch { $failure = $_ }
        Assert-CcodTrue ($null -ne $failure) 'generator fails closed when the Inno source contains multiple Files sections'
        Assert-CcodTrue ($failure.Exception.Message -cmatch 'exactly one \[Files\] section') 'multiple-section failure explains the structural contract'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $output)) 'multiple Files sections produce no partial inventory artifact'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'production setup destination inventory rejects every external include spelling before output' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-installer-external-include-' + [guid]::NewGuid().ToString('N'))
    try {
        $payload = Join-Path $root 'payload'
        [IO.Directory]::CreateDirectory($payload) | Out-Null
        $firstSource = Join-Path $root 'fixture-a.txt'
        [IO.File]::WriteAllText($firstSource,'first',[Text.UTF8Encoding]::new($false))
        $generator = Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1'
        foreach ($fixture in @(
            [pscustomobject]@{Name='plus alias';Directive='#+ "extra.iss"'},
            [pscustomobject]@{Name='include keyword';Directive='#include "extra.iss"'}
        )) {
            $innoPath = Join-Path $root (($fixture.Name -replace '[^A-Za-z]','') + '.iss')
            $innoSource = @"
[Setup]
AppName=ExternalIncludeFixture
AppVersion=1.0.0
DefaultDirName={app}
[Files]
Source: "$firstSource"; DestDir: "{app}\first"; Flags: ignoreversion
[Code]
procedure Fixture();
begin
end;
$($fixture.Directive)
"@
            [IO.File]::WriteAllText($innoPath,$innoSource,[Text.UTF8Encoding]::new($false))
            $inventoryPath = Join-Path $root (($fixture.Name -replace '[^A-Za-z]','') + '-Inventory.iss')
            $generatorFailure = $null
            try {
                & $generator -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $innoPath -OutputPath $inventoryPath | Out-Null
            } catch { $generatorFailure = $_ }
            Assert-CcodTrue ($null -ne $generatorFailure) "generator rejects the $($fixture.Name) before writing inventory"
            Assert-CcodTrue ($generatorFailure.Exception.Message -cmatch 'include') "$($fixture.Name) failure identifies the include-free template boundary"
            Assert-CcodTrue (-not [IO.File]::Exists($inventoryPath)) "$($fixture.Name) produces no partial destination inventory"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'line-spanned include forms are rejected before inventory generation or real ISCC' {
    $iscc = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 is required for the line-spanned include fixtures' }
    . (Join-Path $repositoryRoot 'build\build.ps1') -Library
    $results = [Collections.Generic.List[object]]::new()
    foreach ($fixture in @(
        [pscustomobject]@{Name='line-spanned include keyword';Lines=@('# \','include "extra.iss"')},
        [pscustomobject]@{Name='line-spanned plus alias';Lines=@('# \','+ "extra.iss"')}
    )) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-line-spanned-include-' + [guid]::NewGuid().ToString('N'))
        try {
            $payload = Join-Path $root 'payload'
            $output = Join-Path $root 'output'
            [IO.Directory]::CreateDirectory($payload) | Out-Null
            [IO.Directory]::CreateDirectory($output) | Out-Null
            $firstSource = Join-Path $root 'fixture-a.txt'
            $secondSource = Join-Path $root 'fixture-b.txt'
            [IO.File]::WriteAllText($firstSource,'first',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($secondSource,'second',[Text.UTF8Encoding]::new($false))
            $extraPath = Join-Path $root 'extra.iss'
            $extraSource = @"
[Files]
Source: "$secondSource"; DestDir: "{app}\second"; Flags: ignoreversion
"@
            [IO.File]::WriteAllText($extraPath,$extraSource,[Text.UTF8Encoding]::new($false))
            $templatePath = Join-Path $root 'Template.iss'
            $directive = $fixture.Lines -join "`r`n"
            $templateSource = @"
[Setup]
AppName=LineSpannedInclude
AppVersion=1.0.0
DefaultDirName={tmp}\LineSpannedInclude
OutputDir=$output
OutputBaseFilename=LineSpannedInclude
Uninstallable=no
$directive
[Files]
Source: "$firstSource"; DestDir: "{app}\first"; Flags: ignoreversion
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
"@
            [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $inventoryPath = Join-Path $root 'Inventory.iss'
            $setupPath = Join-Path $output 'LineSpannedInclude.exe'
            $failure = $null
            $compilerAttempted = $false
            try {
                & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $templatePath -OutputPath $inventoryPath | Out-Null
                $compilerAttempted = $true
                Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $iscc -Arguments @() -SetupPath $setupPath
            } catch { $failure = $_ }
            $results.Add([pscustomobject]@{
                Name = $fixture.Name
                Failure = $failure
                CompilerAttempted = $compilerAttempted
                InventoryExists = [IO.File]::Exists($inventoryPath)
                SetupExists = [IO.File]::Exists($setupPath)
                GeneratedCount = @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count
            })
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    foreach ($result in $results) {
        Assert-CcodTrue ($null -ne $result.Failure) "$($result.Name) is rejected before the compiler boundary"
        Assert-CcodTrue ($result.Failure.Exception.Message -cmatch 'preprocessor|continuation') "$($result.Name) failure identifies the strict preprocessor boundary"
        Assert-CcodTrue (-not $result.CompilerAttempted) "$($result.Name) never reaches the real ISCC boundary"
        Assert-CcodTrue (-not $result.InventoryExists) "$($result.Name) leaves no inventory output"
        Assert-CcodTrue (-not $result.SetupExists) "$($result.Name) leaves no setup artifact"
        Assert-CcodEqual 0 $result.GeneratedCount "$($result.Name) leaves no generated compiler input"
    }
}

Invoke-CcodTest 'inventory generation rejects pragma, emit, and unknown simple preprocessor directives' {
    $results = [Collections.Generic.List[object]]::new()
    foreach ($fixture in @(
        [pscustomobject]@{Name='pragma';Directive='#pragma parseroption -u+'},
        [pscustomobject]@{Name='emit';Directive='#emit "[Files]"'},
        [pscustomobject]@{Name='unknown';Directive='#futuredirective "extra.iss"'}
    )) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-unsafe-inno-directive-' + [guid]::NewGuid().ToString('N'))
        try {
            $payload = Join-Path $root 'payload'
            [IO.Directory]::CreateDirectory($payload) | Out-Null
            $sourcePath = Join-Path $root 'fixture.txt'
            [IO.File]::WriteAllText($sourcePath,'fixture',[Text.UTF8Encoding]::new($false))
            $templatePath = Join-Path $root 'Template.iss'
            $templateSource = @"
[Setup]
AppName=UnsafeDirective
AppVersion=1.0.0
DefaultDirName={app}
[Files]
Source: "$sourcePath"; DestDir: "{app}\first"; Flags: ignoreversion
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
$($fixture.Directive)
"@
            [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $inventoryPath = Join-Path $root 'Inventory.iss'
            $failure = $null
            try {
                & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $templatePath -OutputPath $inventoryPath | Out-Null
            } catch { $failure = $_ }
            $results.Add([pscustomobject]@{
                Name = $fixture.Name
                Failure = $failure
                InventoryExists = [IO.File]::Exists($inventoryPath)
            })
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    foreach ($result in $results) {
        Assert-CcodTrue ($null -ne $result.Failure) "$($result.Name) directive is rejected before inventory generation"
        Assert-CcodTrue ($result.Failure.Exception.Message -cmatch 'preprocessor|directive') "$($result.Name) failure identifies the strict directive boundary"
        Assert-CcodTrue (-not $result.InventoryExists) "$($result.Name) directive leaves no inventory output"
    }
}

Invoke-CcodTest 'VT and FF prefixed directives are rejected by inventory and build boundaries before ISCC' {
    $iscc = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 is required for the preprocessor whitespace fixtures' }
    . (Join-Path $repositoryRoot 'build\build.ps1') -Library
    $results = [Collections.Generic.List[object]]::new()
    foreach ($fixture in @(
        [pscustomobject]@{Name='vertical tab';Prefix=[char]0x0B},
        [pscustomobject]@{Name='form feed';Prefix=[char]0x0C}
    )) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-preprocessor-whitespace-' + [guid]::NewGuid().ToString('N'))
        try {
            $payload = Join-Path $root 'payload'
            $realOutput = Join-Path $root 'real-output'
            [IO.Directory]::CreateDirectory($payload) | Out-Null
            [IO.Directory]::CreateDirectory($realOutput) | Out-Null
            $sourcePath = Join-Path $root 'fixture.txt'
            [IO.File]::WriteAllText($sourcePath,'fixture',[Text.UTF8Encoding]::new($false))
            $unsafeDirective = [string]$fixture.Prefix + '#emit ''AppPublisher=InjectedByWhitespace'''
            $templatePath = Join-Path $root 'Template.iss'
            $templateSource = @"
[Setup]
AppName=WhitespaceDirective
AppVersion=1.0.0
DefaultDirName={tmp}\WhitespaceDirective
OutputDir=$realOutput
OutputBaseFilename=WhitespaceDirective
Uninstallable=no
$unsafeDirective
[Files]
Source: "$sourcePath"; DestDir: "{app}\first"; Flags: ignoreversion
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
"@
            [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $inventoryPath = Join-Path $root 'Inventory.iss'
            $realSetupPath = Join-Path $realOutput 'WhitespaceDirective.exe'
            $generatorFailure = $null
            $realCompilerAttempted = $false
            try {
                & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $templatePath -OutputPath $inventoryPath | Out-Null
                $realCompilerAttempted = $true
                Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $iscc -Arguments @() -SetupPath $realSetupPath
            } catch { $generatorFailure = $_ }

            $buildTemplatePath = Join-Path $root 'BuildTemplate.iss'
            [IO.File]::WriteAllText($buildTemplatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $buildInventoryPath = Join-Path $root 'BuildInventory.iss'
            $buildInventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
end;
'@
            [IO.File]::WriteAllText($buildInventoryPath,$buildInventorySource,[Text.UTF8Encoding]::new($false))
            $compilerMarker = Join-Path $root 'fake-iscc-invoked.txt'
            $compilerPath = Join-Path $root 'fake-iscc.cmd'
            $buildSetupPath = Join-Path $root 'build-setup.exe'
            $compilerSource = "@echo off`r`n> `"$compilerMarker`" echo invoked`r`n> `"$buildSetupPath`" echo setup`r`nexit /b 0`r`n"
            [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
            $buildFailure = $null
            try {
                Invoke-CcodBuildInnoCompiler -TemplatePath $buildTemplatePath -InventoryPath $buildInventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $buildSetupPath
            } catch { $buildFailure = $_ }

            $results.Add([pscustomobject]@{
                Name = $fixture.Name
                GeneratorFailure = $generatorFailure
                InventoryExists = [IO.File]::Exists($inventoryPath)
                RealCompilerAttempted = $realCompilerAttempted
                RealSetupExists = [IO.File]::Exists($realSetupPath)
                BuildFailure = $buildFailure
                MarkerCompilerInvoked = [IO.File]::Exists($compilerMarker)
                BuildSetupExists = [IO.File]::Exists($buildSetupPath)
                GeneratedCount = @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count
            })
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    foreach ($result in $results) {
        Assert-CcodTrue ($null -ne $result.GeneratorFailure) "$($result.Name) directive is rejected before inventory generation"
        Assert-CcodTrue ($result.GeneratorFailure.Exception.Message -cmatch 'preprocessor|directive') "$($result.Name) generator failure identifies the preprocessor boundary"
        Assert-CcodTrue (-not $result.InventoryExists) "$($result.Name) leaves no inventory output"
        Assert-CcodTrue (-not $result.RealCompilerAttempted) "$($result.Name) never reaches real ISCC"
        Assert-CcodTrue (-not $result.RealSetupExists) "$($result.Name) leaves no real setup artifact"
        Assert-CcodTrue ($null -ne $result.BuildFailure) "$($result.Name) directive is rejected by generated setup creation"
        Assert-CcodTrue ($result.BuildFailure.Exception.Message -cmatch 'preprocessor|directive') "$($result.Name) build failure identifies the preprocessor boundary"
        Assert-CcodTrue (-not $result.MarkerCompilerInvoked) "$($result.Name) never reaches the marker compiler"
        Assert-CcodTrue (-not $result.BuildSetupExists) "$($result.Name) leaves no marker setup artifact"
        Assert-CcodEqual 0 $result.GeneratedCount "$($result.Name) leaves no generated compiler script"
    }
}

Invoke-CcodTest 'inline file and unsafe define expansion are rejected before inventory or ISCC' {
    $iscc = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 is required for the inline preprocessor fixtures' }
    . (Join-Path $repositoryRoot 'build\build.ps1') -Library
    $results = [Collections.Generic.List[object]]::new()
    foreach ($fixtureName in @('inline file','unsafe define expansion')) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-inline-preprocessor-' + [guid]::NewGuid().ToString('N'))
        try {
            $payload = Join-Path $root 'payload'
            $realOutput = Join-Path $root 'real-output'
            [IO.Directory]::CreateDirectory($payload) | Out-Null
            [IO.Directory]::CreateDirectory($realOutput) | Out-Null
            $mainSource = Join-Path $root 'main.txt'
            $injectedSource = Join-Path $root 'injected.txt'
            $externalText = Join-Path $root 'external.txt'
            [IO.File]::WriteAllText($mainSource,'main',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($injectedSource,'injected',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($externalText,'external text',[Text.UTF8Encoding]::new($false))
            $templatePath = Join-Path $root 'Template.iss'
            if ($fixtureName -ceq 'inline file') {
                $templateSource = @"
[Setup]
AppName=InlineFileDirective
AppVersion=1.0.0
DefaultDirName={tmp}\InlineFileDirective
OutputDir=$realOutput
OutputBaseFilename=InlineFileDirective
Uninstallable=no
LicenseFile={#file "external.txt"}
[Files]
Source: "$mainSource"; DestDir: "{app}\main"; Flags: ignoreversion
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
"@
                $setupName = 'InlineFileDirective.exe'
            } else {
                $templateSource = @"
#define TrayHostArtifactDirectory "[Files]" + NewLine + "Source: ""$injectedSource""; DestDir: ""{app}\injected""; Flags: ignoreversion"
[Setup]
AppName=UnsafeDefineExpansion
AppVersion=1.0.0
DefaultDirName={tmp}\UnsafeDefineExpansion
OutputDir=$realOutput
OutputBaseFilename=UnsafeDefineExpansion
Uninstallable=no
{#TrayHostArtifactDirectory}
[Files]
Source: "$mainSource"; DestDir: "{app}\main"; Flags: ignoreversion
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
"@
                $setupName = 'UnsafeDefineExpansion.exe'
            }
            [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $inventoryPath = Join-Path $root 'Inventory.iss'
            $realSetupPath = Join-Path $realOutput $setupName
            $generatorFailure = $null
            $realCompilerAttempted = $false
            try {
                & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.22' -InnoScriptPath $templatePath -OutputPath $inventoryPath | Out-Null
                $realCompilerAttempted = $true
                Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $iscc -Arguments @() -SetupPath $realSetupPath
            } catch { $generatorFailure = $_ }

            $buildTemplatePath = Join-Path $root 'BuildTemplate.iss'
            [IO.File]::WriteAllText($buildTemplatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $buildInventoryPath = Join-Path $root 'BuildInventory.iss'
            $buildInventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
end;
'@
            [IO.File]::WriteAllText($buildInventoryPath,$buildInventorySource,[Text.UTF8Encoding]::new($false))
            $compilerMarker = Join-Path $root 'fake-iscc-invoked.txt'
            $compilerPath = Join-Path $root 'fake-iscc.cmd'
            $buildSetupPath = Join-Path $root 'build-setup.exe'
            $compilerSource = "@echo off`r`n> `"$compilerMarker`" echo invoked`r`n> `"$buildSetupPath`" echo setup`r`nexit /b 0`r`n"
            [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
            $buildFailure = $null
            try {
                Invoke-CcodBuildInnoCompiler -TemplatePath $buildTemplatePath -InventoryPath $buildInventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $buildSetupPath
            } catch { $buildFailure = $_ }

            $results.Add([pscustomobject]@{
                Name = $fixtureName
                GeneratorFailure = $generatorFailure
                InventoryExists = [IO.File]::Exists($inventoryPath)
                RealCompilerAttempted = $realCompilerAttempted
                RealSetupExists = [IO.File]::Exists($realSetupPath)
                BuildFailure = $buildFailure
                MarkerCompilerInvoked = [IO.File]::Exists($compilerMarker)
                BuildSetupExists = [IO.File]::Exists($buildSetupPath)
                GeneratedCount = @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count
            })
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    foreach ($result in $results) {
        Assert-CcodTrue ($null -ne $result.GeneratorFailure) "$($result.Name) is rejected before inventory generation"
        Assert-CcodTrue ($result.GeneratorFailure.Exception.Message -cmatch 'preprocessor|inline|construct|directive') "$($result.Name) generator failure identifies the strict construct boundary"
        Assert-CcodTrue (-not $result.InventoryExists) "$($result.Name) leaves no inventory output"
        Assert-CcodTrue (-not $result.RealCompilerAttempted) "$($result.Name) never reaches real ISCC"
        Assert-CcodTrue (-not $result.RealSetupExists) "$($result.Name) leaves no real setup artifact"
        Assert-CcodTrue ($null -ne $result.BuildFailure) "$($result.Name) is rejected by generated setup creation"
        Assert-CcodTrue ($result.BuildFailure.Exception.Message -cmatch 'preprocessor|inline|construct|directive') "$($result.Name) build failure identifies the strict construct boundary"
        Assert-CcodTrue (-not $result.MarkerCompilerInvoked) "$($result.Name) never reaches the marker compiler"
        Assert-CcodTrue (-not $result.BuildSetupExists) "$($result.Name) leaves no marker setup artifact"
        Assert-CcodEqual 0 $result.GeneratedCount "$($result.Name) leaves no generated compiler script"
    }
}

Invoke-CcodTest 'generated setup creation applies the same strict preprocessor boundary before ISCC' {
    . (Join-Path $repositoryRoot 'build\build.ps1') -Library
    $results = [Collections.Generic.List[object]]::new()
    foreach ($fixture in @(
        [pscustomobject]@{Name='line-spanned include keyword';Directive=(@('# \','include "extra.iss"') -join "`r`n")},
        [pscustomobject]@{Name='line-spanned plus alias';Directive=(@('# \','+ "extra.iss"') -join "`r`n")},
        [pscustomobject]@{Name='pragma';Directive='#pragma parseroption -u+'},
        [pscustomobject]@{Name='emit';Directive='#emit "[Files]"'},
        [pscustomobject]@{Name='unknown';Directive='#futuredirective "extra.iss"'}
    )) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-generated-unsafe-directive-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            $templatePath = Join-Path $root 'Template.iss'
            $templateSource = @"
[Setup]
AppName=GeneratedUnsafeDirective
AppVersion=1.0.0
DefaultDirName={tmp}\GeneratedUnsafeDirective
OutputBaseFilename=GeneratedUnsafeDirective
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
$($fixture.Directive)
"@
            [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            $inventoryPath = Join-Path $root 'Inventory.iss'
            $inventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
end;
'@
            [IO.File]::WriteAllText($inventoryPath,$inventorySource,[Text.UTF8Encoding]::new($false))
            $compilerMarker = Join-Path $root 'iscc-invoked.txt'
            $compilerPath = Join-Path $root 'fake-iscc.cmd'
            $setupPath = Join-Path $root 'setup.exe'
            $compilerSource = "@echo off`r`n> `"$compilerMarker`" echo invoked`r`n> `"$setupPath`" echo setup`r`nexit /b 0`r`n"
            [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
            $failure = $null
            try {
                Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $setupPath
            } catch { $failure = $_ }
            $results.Add([pscustomobject]@{
                Name = $fixture.Name
                Failure = $failure
                CompilerInvoked = [IO.File]::Exists($compilerMarker)
                SetupExists = [IO.File]::Exists($setupPath)
                GeneratedCount = @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count
            })
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    foreach ($result in $results) {
        Assert-CcodTrue ($null -ne $result.Failure) "$($result.Name) is rejected before generated setup compilation"
        Assert-CcodTrue ($result.Failure.Exception.Message -cmatch 'preprocessor|continuation|directive') "$($result.Name) failure identifies the strict generated-source boundary"
        Assert-CcodTrue (-not $result.CompilerInvoked) "$($result.Name) does not invoke ISCC"
        Assert-CcodTrue (-not $result.SetupExists) "$($result.Name) leaves no setup artifact"
        Assert-CcodEqual 0 $result.GeneratedCount "$($result.Name) leaves no generated compiler input"
    }
}

Invoke-CcodTest 'generated setup rejects an unsafe directive introduced by inventory before ISCC' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-generated-unsafe-inventory-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $templatePath = Join-Path $root 'Template.iss'
        $templateSource = @'
[Setup]
AppName=GeneratedUnsafeInventory
AppVersion=1.0.0
DefaultDirName={tmp}\GeneratedUnsafeInventory
OutputBaseFilename=GeneratedUnsafeInventory
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
'@
        [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
        $inventoryPath = Join-Path $root 'Inventory.iss'
        $inventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
end;
#emit "[Files]"
'@
        [IO.File]::WriteAllText($inventoryPath,$inventorySource,[Text.UTF8Encoding]::new($false))
        $compilerMarker = Join-Path $root 'iscc-invoked.txt'
        $compilerPath = Join-Path $root 'fake-iscc.cmd'
        $setupPath = Join-Path $root 'setup.exe'
        $compilerSource = "@echo off`r`n> `"$compilerMarker`" echo invoked`r`n> `"$setupPath`" echo setup`r`nexit /b 0`r`n"
        [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
        . (Join-Path $repositoryRoot 'build\build.ps1') -Library
        $failure = $null
        try {
            Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $setupPath
        } catch { $failure = $_ }

        Assert-CcodTrue ($null -ne $failure) 'unsafe inventory directive is rejected after marker replacement'
        Assert-CcodTrue ($failure.Exception.Message -cmatch 'preprocessor|directive') 'unsafe inventory failure identifies the final generated-source boundary'
        Assert-CcodTrue (-not [IO.File]::Exists($compilerMarker)) 'unsafe inventory does not invoke ISCC'
        Assert-CcodTrue (-not [IO.File]::Exists($setupPath)) 'unsafe inventory leaves no setup artifact'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count 'unsafe inventory leaves no generated setup script'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'build rejects invalid generated setup inputs before invoking ISCC' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-generated-setup-invalid-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $templatePath = Join-Path $root 'Template.iss'
        $inventoryPath = Join-Path $root 'Inventory.iss'
        $validInventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
end;
'@
        $compilerMarker = Join-Path $root 'iscc-invoked.txt'
        $compilerPath = Join-Path $root 'fake-iscc.cmd'
        $setupPath = Join-Path $root 'setup.exe'
        $compilerSource = "@echo off`r`n> `"$compilerMarker`" echo invoked`r`n> `"$setupPath`" echo setup`r`nexit /b 0`r`n"
        [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
        . (Join-Path $repositoryRoot 'build\build.ps1') -Library
        foreach ($fixture in @(
            [pscustomobject]@{Name='include keyword';Directive='#include "extra.iss"'},
            [pscustomobject]@{Name='plus alias';Directive='#+ "extra.iss"'}
        )) {
            $templateSource = @"
[Setup]
AppName=InvalidGeneratedSetup
AppVersion=1.0.0
DefaultDirName={tmp}\InvalidGeneratedSetup
OutputBaseFilename=InvalidGeneratedSetup
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
$($fixture.Directive)
"@
            [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($inventoryPath,$validInventorySource,[Text.UTF8Encoding]::new($false))
            $failure = $null
            try {
                Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $setupPath
            } catch { $failure = $_ }
            Assert-CcodTrue ($null -ne $failure) "build rejects the $($fixture.Name) before ISCC"
            Assert-CcodTrue ($failure.Exception.Message -cmatch 'include') "$($fixture.Name) failure identifies the include-free compiler boundary"
            Assert-CcodTrue (-not [IO.File]::Exists($compilerMarker)) "$($fixture.Name) does not launch ISCC"
            Assert-CcodTrue (-not [IO.File]::Exists($setupPath)) "$($fixture.Name) produces no setup artifact"
            Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count "$($fixture.Name) leaves no generated setup script"
        }

        $validTemplateSource = @'
[Setup]
AppName=InvalidInventory
AppVersion=1.0.0
DefaultDirName={tmp}\InvalidInventory
OutputBaseFilename=InvalidInventory
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
'@
        $invalidInventorySource = $validInventorySource + "`r`n[Files]`r`n"
        [IO.File]::WriteAllText($templatePath,$validTemplateSource,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($inventoryPath,$invalidInventorySource,[Text.UTF8Encoding]::new($false))
        $inventoryFailure = $null
        try {
            Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $setupPath
        } catch { $inventoryFailure = $_ }
        Assert-CcodTrue ($null -ne $inventoryFailure) 'build rejects a generated inventory carrying an Inno section header'
        Assert-CcodTrue ($inventoryFailure.Exception.Message -cmatch 'section header') 'inventory validation explains the forbidden section header'
        Assert-CcodTrue (-not [IO.File]::Exists($compilerMarker)) 'invalid inventory does not launch ISCC'
        Assert-CcodTrue (-not [IO.File]::Exists($setupPath)) 'invalid inventory produces no setup artifact'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count 'invalid inventory leaves no generated setup script'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'build passes only a GUID generated include-free setup to ISCC and cleans it' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-generated-setup-valid-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $templatePath = Join-Path $root 'Template.iss'
        $templateSource = @'
[Setup]
AppName=GeneratedSetup
AppVersion=1.0.0
DefaultDirName={tmp}\GeneratedSetup
OutputBaseFilename=GeneratedSetup
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
'@
        [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
        $inventoryPath = Join-Path $root 'Inventory.iss'
        $inventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
  Directories.Add('payload\2.5.22');
end;
'@
        [IO.File]::WriteAllText($inventoryPath,$inventorySource,[Text.UTF8Encoding]::new($false))
        $compilerArgument = Join-Path $root 'iscc-argument.txt'
        $capturedSource = Join-Path $root 'compiled-source.iss'
        $compilerPath = Join-Path $root 'fake-iscc.cmd'
        $setupPath = Join-Path $root 'setup.exe'
        $compilerSource = "@echo off`r`n> `"$compilerArgument`" echo %~f1`r`ncopy /y `"%~1`" `"$capturedSource`" >nul`r`n> `"$setupPath`" echo setup`r`nexit /b 0`r`n"
        [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
        . (Join-Path $repositoryRoot 'build\build.ps1') -Library

        Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $setupPath

        Assert-CcodTrue ([IO.File]::Exists($setupPath)) 'validated generated source accepts the compiler setup artifact'
        Assert-CcodTrue ([IO.File]::Exists($capturedSource)) 'compiler receives a readable generated setup source'
        $compiledPath = [IO.File]::ReadAllText($compilerArgument).Trim()
        Assert-CcodTrue (-not $compiledPath.Equals([IO.Path]::GetFullPath($templatePath),[StringComparison]::OrdinalIgnoreCase)) 'ISCC never receives the checked-in template path'
        Assert-CcodTrue ([IO.Path]::GetFileName($compiledPath) -cmatch '^\.ccod-generated-setup-[0-9a-f]{32}\.iss$') 'ISCC receives the GUID-named generated setup path'
        Assert-CcodTrue (-not [IO.File]::Exists($compiledPath)) 'generated compiler input is cleaned after ISCC returns'
        $compiledSource = [IO.File]::ReadAllText($capturedSource,[Text.UTF8Encoding]::new($false))
        Assert-CcodTrue ($compiledSource.Contains("Directories.Add('payload\2.5.22');")) 'compiled source contains the verified injected inventory procedure'
        Assert-CcodTrue (-not $compiledSource.Contains('// CCOD_INSTALLER_DESTINATION_INVENTORY')) 'compiled source contains no unresolved inventory marker'
        Assert-CcodTrue ($compiledSource -cnotmatch '(?m)^\s*#\s*(?:include\b|\+)') 'compiled source contains no external include directive'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count 'successful compile leaves no generated setup script'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'build cleans the GUID generated setup when ISCC returns nonzero' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-generated-setup-compiler-failure-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $templatePath = Join-Path $root 'Template.iss'
        $templateSource = @'
[Setup]
AppName=GeneratedSetupCompilerFailure
AppVersion=1.0.0
DefaultDirName={tmp}\GeneratedSetupCompilerFailure
OutputBaseFilename=GeneratedSetupCompilerFailure
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
'@
        [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
        $inventoryPath = Join-Path $root 'Inventory.iss'
        $inventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
end;
'@
        [IO.File]::WriteAllText($inventoryPath,$inventorySource,[Text.UTF8Encoding]::new($false))
        $compilerArgument = Join-Path $root 'iscc-argument.txt'
        $compilerPath = Join-Path $root 'fake-iscc.cmd'
        $setupPath = Join-Path $root 'setup.exe'
        $compilerSource = "@echo off`r`n> `"$compilerArgument`" echo %~f1`r`nexit /b 23`r`n"
        [IO.File]::WriteAllText($compilerPath,$compilerSource,[Text.ASCIIEncoding]::new())
        . (Join-Path $repositoryRoot 'build\build.ps1') -Library
        $failure = $null
        try {
            Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $compilerPath -Arguments @() -SetupPath $setupPath
        } catch { $failure = $_ }

        Assert-CcodTrue ($null -ne $failure) 'nonzero ISCC exit fails the build boundary'
        Assert-CcodTrue ($failure.Exception.Message -cmatch 'exit code 23') 'compiler failure retains the exact nonzero exit code'
        Assert-CcodTrue ([IO.File]::Exists($compilerArgument)) 'nonzero compiler records the generated source argument'
        $compiledPath = [IO.File]::ReadAllText($compilerArgument).Trim()
        Assert-CcodTrue ([IO.Path]::GetFileName($compiledPath) -cmatch '^\.ccod-generated-setup-[0-9a-f]{32}\.iss$') 'nonzero compiler receives the GUID generated source'
        Assert-CcodTrue (-not [IO.File]::Exists($compiledPath)) 'nonzero compiler path is removed by the build finally boundary'
        Assert-CcodTrue (-not [IO.File]::Exists($setupPath)) 'nonzero compiler produces no accepted setup artifact'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count 'nonzero compiler leaves no generated setup script'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'real ISCC compiles the generated setup with its injected inventory procedure' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-generated-setup-iscc-' + [guid]::NewGuid().ToString('N'))
    try {
        $output = Join-Path $root 'output'
        [IO.Directory]::CreateDirectory($output) | Out-Null
        $templatePath = Join-Path $root 'Template.iss'
        $templateSource = @"
[Setup]
AppName=GeneratedSetupRealCompiler
AppVersion=1.0.0
DefaultDirName={tmp}\GeneratedSetupRealCompiler
OutputDir=$output
OutputBaseFilename=GeneratedSetupRealCompiler
Uninstallable=no
[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
function InitializeSetup(): Boolean;
var
  Directories: TStringList;
begin
  Directories := TStringList.Create;
  try
    AddCcodExpectedSetupDirectories(Directories);
    Result := Directories.Count = 1;
  finally
    Directories.Free;
  end;
end;
"@
        [IO.File]::WriteAllText($templatePath,$templateSource,[Text.UTF8Encoding]::new($false))
        $inventoryPath = Join-Path $root 'Inventory.iss'
        $inventorySource = @'
procedure AddCcodExpectedSetupDirectories(Directories: TStrings);
begin
  Directories.Add('payload\2.5.22');
end;
'@
        [IO.File]::WriteAllText($inventoryPath,$inventorySource,[Text.UTF8Encoding]::new($false))
        $iscc = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        ) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
        if (-not $iscc) { throw 'Inno Setup 6 is required for the generated setup fixture' }
        $setupPath = Join-Path $output 'GeneratedSetupRealCompiler.exe'
        . (Join-Path $repositoryRoot 'build\build.ps1') -Library

        Invoke-CcodBuildInnoCompiler -TemplatePath $templatePath -InventoryPath $inventoryPath -IsccPath $iscc -Arguments @() -SetupPath $setupPath

        Assert-CcodTrue ([IO.File]::Exists($setupPath)) 'real ISCC compiles the injected inventory procedure and its call site'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $root -Filter '.ccod-generated-setup-*.iss' -File -Force).Count 'real ISCC compile leaves no generated setup script'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

function New-CcodActivationPayloadFixture {
    param([string]$Version = '2.5.22')

    $appRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-payload-' + [guid]::NewGuid().ToString('N'))
    $payloadRoot = Join-Path $appRoot "payload\$Version"
    [IO.Directory]::CreateDirectory((Join-Path $payloadRoot 'src\persistence\modules')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'package.json'),([ordered]@{name='fixture';version=$Version}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $installSource = @'
param(
    [string]$InstallRoot,
    [switch]$EnableCandidateCompatibleUpdates,
    [string]$ActivationId,
    [string]$ExpectedVersion,
    [string]$PayloadManifestPath,
    [string]$ExpectedPayloadManifestSha256,
    [string]$SealedPackageSha256
)
$null = [IO.Directory]::CreateDirectory($InstallRoot)
[IO.File]::WriteAllText((Join-Path $InstallRoot 'sealed-package-sha256.txt'),[string]$SealedPackageSha256,[Text.UTF8Encoding]::new($false))
$manifest = [IO.File]::ReadAllText($PayloadManifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot 'src\persistence\modules\InstallLifecycle.psm1') -Force
Invoke-CcodFixtureInstall -InstallRoot $InstallRoot -ActivationId $ActivationId -ManifestVersion ([string]$manifest.projectVersion)
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'Install-CodexControlOtherDevices.ps1'),$installSource,[Text.UTF8Encoding]::new($false))
    $lifecycleSource = @'
function Invoke-CcodFixtureInstall {
    param([string]$InstallRoot,[string]$ActivationId,[string]$ManifestVersion)
    [IO.Directory]::CreateDirectory((Join-Path $InstallRoot 'state\activation-receipts')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'activation-byte-marker.txt'),('original:' + $ManifestVersion),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'active.json'),'{"activeRuntime":"runtime-fixture"}',[Text.UTF8Encoding]::new($false))
    $receipt=[ordered]@{schemaVersion=1;activationId=$ActivationId;phase='Ready';runtimeId='runtime-fixture';previousRuntimeId=$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=$true;errorCode=$null}
    [IO.File]::WriteAllText((Join-Path $InstallRoot "state\activation-receipts\$ActivationId.Ready.json"),($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
Export-ModuleMember -Function Invoke-CcodFixtureInstall
'@
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'src\persistence\modules\InstallLifecycle.psm1'),$lifecycleSource,[Text.UTF8Encoding]::new($false))
    $runtimeManifestSource = @"
function Read-CcodActiveRuntime { param([string]`$InstallRoot) Get-Content -LiteralPath (Join-Path `$InstallRoot 'active.json') -Raw | ConvertFrom-Json }
function Test-CcodRuntimeManifest { param([string]`$RuntimeDirectory,[string]`$ExpectedRuntimeId) [pscustomobject]@{Valid=`$true;Manifest=[pscustomobject]@{projectVersion='$Version'}} }
Export-ModuleMember -Function Read-CcodActiveRuntime,Test-CcodRuntimeManifest
"@
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'src\persistence\modules\RuntimeManifest.psm1'),$runtimeManifestSource,[Text.UTF8Encoding]::new($false))
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $payloadRoot -File -Force -Recurse)) {
        $relative = $file.FullName.Substring($payloadRoot.TrimEnd('\').Length + 1).Replace('\','/')
        $records.Add([pscustomobject][ordered]@{path=$relative;length=[int64]$file.Length;sha256=Get-CcodTestFileSha256 -Path $file.FullName})
    }
    $comparison = [System.Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)}
    $records.Sort($comparison)
    $manifestPath = Join-Path $payloadRoot 'installer-payload.manifest.json'
    [IO.File]::WriteAllText($manifestPath,([ordered]@{schemaVersion=1;projectVersion=$Version;files=@($records)}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{AppRoot=$appRoot;PayloadRoot=$payloadRoot;ManifestPath=$manifestPath;ManifestSha256=Get-CcodTestFileSha256 -Path $manifestPath}
}

function New-CcodActivationBarrierHost {
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter(Mandatory)][string]$ContinuePath,
        [Parameter(Mandatory)][string]$RealPowerShellPath
    )

    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $outputPath = Join-Path $OutputDirectory 'powershell.exe'
    $source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public static class Program {
  private static string Quote(string value) {
    var result = new StringBuilder(); result.Append((char)34); int slashes = 0;
    foreach (char character in value) {
      if (character == (char)92) { slashes++; continue; }
      if (character == (char)34) { result.Append(new string((char)92, (slashes * 2) + 1)); result.Append((char)34); slashes = 0; continue; }
      if (slashes > 0) { result.Append(new string((char)92, slashes)); slashes = 0; }
      result.Append(character);
    }
    if (slashes > 0) result.Append(new string((char)92, slashes * 2));
    result.Append((char)34); return result.ToString();
  }
  public static int Main(string[] args) {
    File.WriteAllText(@"$($ReadyPath.Replace('"','""'))", "ready", new UTF8Encoding(false));
    var deadline = DateTime.UtcNow.AddSeconds(30);
    while (!File.Exists(@"$($ContinuePath.Replace('"','""'))")) { if (DateTime.UtcNow >= deadline) return 124; Thread.Sleep(10); }
    var info = new ProcessStartInfo(@"$($RealPowerShellPath.Replace('"','""'))", String.Join(" ", Array.ConvertAll(args, Quote)));
    info.UseShellExecute = false; info.CreateNoWindow = true;
    using (var process = Process.Start(info)) { process.WaitForExit(); return process.ExitCode; }
  }
}
"@
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $outputPath -OutputType ConsoleApplication
    return $outputPath
}

function Invoke-CcodActivationVerifierFixture {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ExpectedManifestSha256,[string]$PayloadRoot)

    $stdoutPath = Join-Path $Fixture.AppRoot ('stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path $Fixture.AppRoot ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    if ([string]::IsNullOrWhiteSpace($PayloadRoot)) { $PayloadRoot = $Fixture.PayloadRoot }
    $argumentLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -AppRoot "{1}" -InstallRoot "{1}" -PayloadRoot "{2}" -ExpectedVersion "2.5.22" -ExpectedPayloadManifestSha256 "{3}" -ActivationId "77777777-6666-5555-4444-333333333333" -ValidateReceiptOnly' -f (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'),$Fixture.AppRoot,$PayloadRoot,$ExpectedManifestSha256
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru
    try { $exitCode = [int]$process.ExitCode } finally { $process.Dispose() }
    return [pscustomobject]@{ExitCode=$exitCode;Output=([IO.File]::ReadAllText($stdoutPath)+[IO.File]::ReadAllText($stderrPath))}
}

# Production mutation caught: verifying package bytes but invoking a legacy source root without propagating package identity.
Invoke-CcodTest 'temporary bootstrap verifies the sealed package and propagates its exact hash to the installer child' {
    $fixture = New-CcodActivationPayloadFixture
    $module = $null
    try {
        $packagePath = Join-Path $fixture.AppRoot 'sealed-installer.zip'
        $packageManifestPath = Join-Path $fixture.AppRoot 'sealed-installer.manifest.json'
        $module = Import-Module (Join-Path $repositoryRoot 'build\InstallerPackage.psm1') -Force -PassThru
        $created = New-CcodInstallerPackage -PayloadRoot $fixture.PayloadRoot -PayloadManifestPath $fixture.ManifestPath -Version '2.5.22' -GitCommit ('d' * 40) -OutputPath $packagePath -ManifestOutputPath $packageManifestPath
        $installRoot = Join-Path $fixture.AppRoot 'installed-state'
        $activationId = '77777777-6666-5555-4444-333333333333'
        $setupScanObservation=[pscustomobject]@{Path=$null}
        function Get-MpComputerStatus {[pscustomobject]@{AMServiceEnabled=$true;AntivirusEnabled=$true;RealTimeProtectionEnabled=$true;AMProductVersion='fixture-platform';AMEngineVersion='fixture-engine';AntivirusSignatureVersion='fixture-signature';AntivirusSignatureLastUpdated=[datetime]::UtcNow.AddHours(-1)}}
        function Get-MpThreatDetection {param($ErrorAction)@()}
        function Start-MpScan {param($ScanType,$ScanPath,$ErrorAction)$setupScanObservation.Path=[string]$ScanPath}
        $output = @(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -InstallRoot $installRoot -PackagePath $packagePath -PackageManifestPath $packageManifestPath -ExpectedPackageSha256 $created.PackageSha256 -ExpectedPackageManifestSha256 $created.ManifestSha256 -ExpectedVersion '2.5.22' -ExpectedGitCommit ('d' * 40) -ActivationId $activationId 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE "sealed package bootstrap completes: $($output -join ' ')"
        Assert-CcodEqual ([IO.Path]::GetFullPath($packagePath)) ([string]$setupScanObservation.Path) 'Setup scans the canonical package path returned by the held seal'
        Assert-CcodEqual $created.PackageSha256 ([IO.File]::ReadAllText((Join-Path $installRoot 'sealed-package-sha256.txt'),[Text.UTF8Encoding]::new($false))) 'child receives the exact verified package identity'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $installRoot "state\activation-receipts\$activationId.Ready.json") -PathType Leaf) 'bootstrap accepts only the append-only Ready receipt'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $installRoot 'state\post-install-activation.json'))) 'bootstrap never creates or consumes the mutable legacy receipt'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask5Test 'entrypoints' 'Setup Defender failure occurs after sealing and before temp expansion or activation mutation' {
    $productionPath=Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'
    $productionSource=[IO.File]::ReadAllText($productionPath,[Text.UTF8Encoding]::new($false,$true))
    $needle='$packageDefender = Invoke-CcodSetupPackageDefenderGate -PackagePath ([string]$packageSeal.PackagePath)'
    Assert-CcodEqual 1 ([regex]::Matches($productionSource,[regex]::Escape($needle)).Count) 'Setup invokes the package Defender gate exactly once from the sealed-package branch'
    $sealIndex=$productionSource.IndexOf('$packageSeal = Open-CcodInstallerPackageSeal',[StringComparison]::Ordinal)
    $scanIndex=$productionSource.IndexOf($needle,[StringComparison]::Ordinal)
    $tempIndex=$productionSource.IndexOf('$packageAppRoot = Join-Path',[StringComparison]::Ordinal)
    Assert-CcodTrue ($sealIndex-ge0-and$scanIndex-gt$sealIndex-and$tempIndex-gt$scanIndex) 'Setup scan is ordered after exact seal and before the first extraction temp path'

    $fixture=New-CcodActivationPayloadFixture
    $module=$null
    try{
        $packagePath=Join-Path $fixture.AppRoot 'sealed-installer.zip';$packageManifestPath=Join-Path $fixture.AppRoot 'sealed-installer.manifest.json'
        $module=Import-Module (Join-Path $repositoryRoot 'build\InstallerPackage.psm1') -Force -PassThru
        $created=New-CcodInstallerPackage -PayloadRoot $fixture.PayloadRoot -PayloadManifestPath $fixture.ManifestPath -Version '2.5.22' -GitCommit ('d'*40) -OutputPath $packagePath -ManifestOutputPath $packageManifestPath
        $injectedPath=Join-Path $fixture.AppRoot 'Activate-CcodRemoteFix-defender-failure.ps1'
        $injectedSource=$productionSource.Replace($needle,"throw 'CCOD_SETUP_DEFENDER_SCAN_FAILED'")
        Assert-CcodTrue ($injectedSource-cne$productionSource) 'test injection replaces only the real Setup Defender call boundary'
        [IO.File]::WriteAllText($injectedPath,$injectedSource,[Text.UTF8Encoding]::new($false))
        $installRoot=Join-Path $fixture.AppRoot 'must-remain-absent';$before=Get-CcodReadOnlyProductTreeSnapshot -Root $installRoot
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());$beforeTemps=@(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'ccod-activation-package-*' -Force -ErrorAction Stop|ForEach-Object{$_.FullName}|Sort-Object)
        $output=@(&$injectedPath -InstallRoot $installRoot -PackagePath $packagePath -PackageManifestPath $packageManifestPath -ExpectedPackageSha256 $created.PackageSha256 -ExpectedPackageManifestSha256 $created.ManifestSha256 -ExpectedVersion '2.5.22' -ExpectedGitCommit ('d'*40) -ActivationId '77777777-6666-5555-4444-333333333333' 2>&1)
        Assert-CcodEqual 3 $LASTEXITCODE "injected sealed-package Defender failure is rejected: $($output-join' ')"
        Assert-CcodTrue (($output-join"`n")-cmatch'CCOD_SETUP_DEFENDER_SCAN_FAILED') 'Setup preserves the stable scan failure code'
        $after=Get-CcodReadOnlyProductTreeSnapshot -Root $installRoot
        Assert-CcodEqual ($before|ConvertTo-Json -Depth 8 -Compress) ($after|ConvertTo-Json -Depth 8 -Compress) 'Setup scan failure creates no Prepared receipt transaction product or worker state'
        $afterTemps=@(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'ccod-activation-package-*' -Force -ErrorAction Stop|ForEach-Object{$_.FullName}|Sort-Object)
        Assert-CcodEqual ($beforeTemps-join'|') ($afterTemps-join'|') 'Setup scan failure creates no package expansion directory'
    }finally{
        if($null-ne$module){Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue}
        if(Test-Path $fixture.AppRoot){Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

function Invoke-CcodInnoPayloadCompileFixture {
    param([switch]$IncludePayloadDefines,[switch]$OmitDestinationInventory,[switch]$BindWrongPackageHash,[switch]$UseInertActivationMarker)

    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-inno-payload-contract-' + [guid]::NewGuid().ToString('N'))
    $tray = Join-Path $root 'tray'
    $portable = Join-Path $root 'portable'
    $payload = Join-Path $root 'payload'
    $output = Join-Path $root 'output'
    foreach ($directory in @($tray,$portable,$payload,$output)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    foreach ($leaf in @('CodexRemote.TrayHost.exe','CodexRemote.TrayHost.exe.config','trayhost-build-provenance.json')) {
        [IO.File]::WriteAllText((Join-Path $tray $leaf),"fixture $leaf",[Text.UTF8Encoding]::new($false))
    }
    foreach ($leaf in @('CodexRemote.Portable.exe','CodexRemote.Portable.exe.config','portable-launcher-provenance.json')) {
        [IO.File]::WriteAllText((Join-Path $portable $leaf),"fixture $leaf",[Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $payload 'package.json'),'{"version":"2.5.21"}',[Text.UTF8Encoding]::new($false))
    $packageHash = Get-CcodTestFileSha256 -Path (Join-Path $payload 'package.json')
    $manifest = [ordered]@{schemaVersion=1;projectVersion='2.5.21';files=@([ordered]@{path='package.json';length=[int64](Get-Item -LiteralPath (Join-Path $payload 'package.json')).Length;sha256=$packageHash})}
    $manifestPath = Join-Path $payload 'installer-payload.manifest.json'
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $inventoryPath = Join-Path $root 'InstallerDestinationInventory.iss'
    $templatePath = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    if (-not $OmitDestinationInventory) {
        & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $payload -ProjectVersion '2.5.21' -InnoScriptPath $templatePath -OutputPath $inventoryPath | Out-Null
    }
    $iscc = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 is required for the setup payload contract' }
    $payloadManifestSha256 = Get-CcodTestFileSha256 -Path $manifestPath
    $setupGitCommit = 'c' * 40
    Import-Module (Join-Path $repositoryRoot 'build\InstallerPackage.psm1') -Force
    $installerPackagePath = Join-Path $root 'installer-package.zip'
    $installerPackageManifestPath = Join-Path $root 'installer-package.manifest.json'
    $installerPackage = New-CcodInstallerPackage -PayloadRoot $payload -PayloadManifestPath $manifestPath -Version '2.5.21' -GitCommit $setupGitCommit -OutputPath $installerPackagePath -ManifestOutputPath $installerPackageManifestPath
    $activationMarker = Join-Path $root 'activation-executed.txt'
    $activationBootstrapPath = if($UseInertActivationMarker){
        $path=Join-Path $root 'inert-activation-bootstrap.ps1'
        [IO.File]::WriteAllText($path,"[IO.File]::WriteAllText('$($activationMarker.Replace("'","''"))','executed',[Text.UTF8Encoding]::new(`$false));exit 97",[Text.UTF8Encoding]::new($false))
        $path
    }else{Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'}
    $activationBootstrapSha256 = Get-CcodTestFileSha256 -Path $activationBootstrapPath
    $setupProvenancePath = Join-Path $root 'setup-provenance.json'
    [IO.File]::WriteAllText($setupProvenancePath,'{}',[Text.UTF8Encoding]::new($false))
    $boundPackageHash=$null
    $arguments = @('/DProjectVersion=2.5.21',"/DSetupGitCommit=$setupGitCommit","/DSetupProvenancePath=$setupProvenancePath","/O$output\")
    if ($IncludePayloadDefines) {
        $boundPackageHash=if($BindWrongPackageHash){'0'*64}else{[string]$installerPackage.PackageSha256}
        $arguments = @('/DProjectVersion=2.5.21',"/DInstallerPackagePath=$installerPackagePath","/DInstallerPackageManifestPath=$installerPackageManifestPath","/DInstallerPackageSha256=$boundPackageHash","/DInstallerPackageManifestSha256=$($installerPackage.ManifestSha256)","/DActivationBootstrapPath=$activationBootstrapPath","/DActivationBootstrapSha256=$activationBootstrapSha256","/DSetupGitCommit=$setupGitCommit","/DSetupProvenancePath=$setupProvenancePath")
        $arguments += "/O$output\"
    }
    . (Join-Path $repositoryRoot 'build\build.ps1') -Library
    $generatedPath = Join-Path (Split-Path $templatePath -Parent) ('.ccod-generated-setup-' + [guid]::NewGuid().ToString('N') + '.iss')
    $generatedSource = ''
    $compileOutput = @()
    $exitCode = 1
    try {
        $generated = New-CcodBuildGeneratedInnoScript -TemplatePath $templatePath -InventoryPath $inventoryPath -OutputPath $generatedPath
        $generatedSource = [IO.File]::ReadAllText($generated,[Text.UTF8Encoding]::new($false))
        $arguments += $generated
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $compileOutput = @(& $iscc @arguments 2>&1)
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
    } catch {
        $compileOutput = @($_.Exception.Message)
        $exitCode = 1
    } finally {
        if ([IO.File]::Exists($generatedPath)) { Remove-Item -LiteralPath $generatedPath -Force }
    }
    return [pscustomobject]@{
        Root = $root
        ExitCode = $exitCode
        Output = ($compileOutput -join "`n")
        SetupPath = (Join-Path $output 'CodexRemote-fix-2.5.21-setup.exe')
        GeneratedPath = $generatedPath
        GeneratedSource = $generatedSource
        PayloadManifestSha256 = $payloadManifestSha256
        PackageSha256 = $installerPackage.PackageSha256
        PackageManifestSha256 = $installerPackage.ManifestSha256
        ActivationBootstrapSha256 = $activationBootstrapSha256
        SetupGitCommit = $setupGitCommit
        PackagePath = $installerPackagePath
        PackageManifestPath = $installerPackageManifestPath
        ActivationBootstrapPath = $activationBootstrapPath
        InventoryPath = $inventoryPath
        TemplatePath = $templatePath
        CompilerPath = $iscc
        ActivationMarker = $activationMarker
        BoundPackageSha256 = $boundPackageHash
    }
}

Invoke-CcodTest 'setup build and activation bind one immutable versioned payload end to end' {
    $build = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw -Encoding UTF8
    $inno = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activation = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -Raw -Encoding UTF8
    $installer = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Install-CodexControlOtherDevices.ps1') -Raw -Encoding UTF8
    $setupArtifact = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\SetupArtifact.psm1') -Raw -Encoding UTF8

    Assert-CcodTrue ($build -cmatch 'New-InstallerPayloadManifest\.ps1' -and $build -cmatch 'InstallerPackage\.psm1' -and $build -cmatch 'New-CcodInstallerPackage' -and $build -cmatch 'New-CcodBuildGeneratedInnoScript') 'build creates the sealed package and binds it into generated setup compilation'
    Assert-CcodTrue ($inno -cmatch 'InstallerPackagePath' -and $inno -cmatch 'ExtractTemporaryFile\(.ccod-installer-package\.zip.' -and $inno -cnotmatch 'DestDir:\s*"\{app\}') 'Inno extracts only the sealed package to private temporary storage'
    Assert-CcodTrue ($inno -cmatch '-ExpectedPackageSha256\s+"\{#InstallerPackageSha256' -and $inno -cmatch '-ExpectedVersion\s+"\{#ProjectVersion') 'Inno binds activation to its compiled package identity and version'
    Assert-CcodTrue ($activation -cmatch '\[string\]\$PackagePath' -and $activation -cmatch '\[string\]\$ExpectedPackageSha256' -and $activation -cmatch 'Open-CcodInstallerPackageSeal') 'activation accepts and opens the sealed package contract'
    Assert-CcodTrue ($installer -cmatch '\[string\]\$SealedPackageSha256' -and $installer -cmatch '\$invoke\.SealedPackageSha256\s*=\s*\$SealedPackageSha256') 'installer explicitly forwards the exact sealed package identity to lifecycle activation'
    Assert-CcodTrue ($setupArtifact -cmatch 'New-CcodSealedSetupBuildProvenance' -and $setupArtifact -cmatch 'Test-CcodSealedSetupBuildProvenance' -and $build -cmatch 'New-CcodSealedSetupBuildProvenance' -and $build -cmatch 'Test-CcodSealedSetupBuildProvenance') 'Setup provenance creates and verifies package manifest and bootstrap bindings'
}

# Production mutation caught: reopening mutable payload paths after the parent accepted their manifest bytes.
Invoke-CcodTest 'activation executes only the verified manifest installer and module bytes across the child-launch barrier' {
    $fixture = New-CcodActivationPayloadFixture
    $barrierRoot = Join-Path $fixture.AppRoot 'barrier-host'
    $readyPath = Join-Path $fixture.AppRoot 'child-launch.ready'
    $continuePath = Join-Path $fixture.AppRoot 'child-launch.continue'
    $stdoutPath = Join-Path $fixture.AppRoot 'activation.stdout'
    $stderrPath = Join-Path $fixture.AppRoot 'activation.stderr'
    $process = $null
    try {
        $realPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $null = New-CcodActivationBarrierHost -OutputDirectory $barrierRoot -ReadyPath $readyPath -ContinuePath $continuePath -RealPowerShellPath $realPowerShell
        $activationId = '77777777-6666-5555-4444-333333333333'
        $arguments = @(
            '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'),
            '-AppRoot',$fixture.AppRoot,'-InstallRoot',$fixture.AppRoot,'-PayloadRoot',$fixture.PayloadRoot,
            '-ExpectedVersion','2.5.22','-ExpectedPayloadManifestSha256',$fixture.ManifestSha256,'-ActivationId',$activationId,
            '-FirstReceiptTimeoutMilliseconds','30000','-ActivationTimeoutMilliseconds','30000'
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $realPowerShell
        $startInfo.Arguments = (($arguments | ForEach-Object { '"' + ([string]$_).Replace('\','\').Replace('"','\"') + '"' }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['PATH'] = $barrierRoot + ';' + $env:PATH
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        Assert-CcodTrue $process.Start() 'activation fixture process starts'

        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not [IO.File]::Exists($readyPath) -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
            [Threading.Thread]::Sleep(10)
        }
        $barrierFailure = if ($process.HasExited) { $process.StandardOutput.ReadToEnd() + ' ' + $process.StandardError.ReadToEnd() } else { '' }
        Assert-CcodTrue ([IO.File]::Exists($readyPath)) "barrier proves parent payload verification completed before child execution: $barrierFailure"

        $replacementInstallerMarker = Join-Path $fixture.AppRoot 'replacement-installer-executed.txt'
        $replacementInstaller = @"
param([string]`$InstallRoot,[switch]`$EnableCandidateCompatibleUpdates,[string]`$ActivationId,[string]`$ExpectedVersion,[string]`$PayloadManifestPath,[string]`$ExpectedPayloadManifestSha256)
[IO.File]::WriteAllText('$($replacementInstallerMarker.Replace("'","''"))','executed',[Text.UTF8Encoding]::new(`$false))
`$manifest=[IO.File]::ReadAllText(`$PayloadManifestPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
Import-Module (Join-Path `$PSScriptRoot 'src\persistence\modules\InstallLifecycle.psm1') -Force
Invoke-CcodFixtureInstall -InstallRoot `$InstallRoot -ActivationId `$ActivationId -ManifestVersion ([string]`$manifest.projectVersion)
exit 0
"@
        [IO.File]::WriteAllText((Join-Path $fixture.PayloadRoot 'Install-CodexControlOtherDevices.ps1'),$replacementInstaller,[Text.UTF8Encoding]::new($false))
        $replacementModule = @'
function Invoke-CcodFixtureInstall {
    param([string]$InstallRoot,[string]$ActivationId,[string]$ManifestVersion)
    [IO.Directory]::CreateDirectory((Join-Path $InstallRoot 'state\activation-receipts')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'activation-byte-marker.txt'),('replacement:' + $ManifestVersion),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'active.json'),'{"activeRuntime":"runtime-fixture"}',[Text.UTF8Encoding]::new($false))
    $receipt=[ordered]@{schemaVersion=1;activationId=$ActivationId;phase='Ready';runtimeId='runtime-fixture';previousRuntimeId=$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=$true;errorCode=$null}
    [IO.File]::WriteAllText((Join-Path $InstallRoot "state\activation-receipts\$ActivationId.Ready.json"),($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
Export-ModuleMember -Function Invoke-CcodFixtureInstall
'@
        [IO.File]::WriteAllText((Join-Path $fixture.PayloadRoot 'src\persistence\modules\InstallLifecycle.psm1'),$replacementModule,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($fixture.ManifestPath,'{"schemaVersion":1,"projectVersion":"9.9.9","files":[]}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($continuePath,'continue',[Text.UTF8Encoding]::new($false))

        Assert-CcodTrue $process.WaitForExit(30000) 'activation fixture finishes within the bounded child deadline'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-CcodEqual 0 ([int]$process.ExitCode) "verified fixture activation succeeds: $stdout $stderr"
        Assert-CcodEqual 'original:2.5.22' ([IO.File]::ReadAllText((Join-Path $fixture.AppRoot 'activation-byte-marker.txt'),[Text.UTF8Encoding]::new($false))) 'child executes and parses only the original verified bytes'
        Assert-CcodTrue (-not [IO.File]::Exists($replacementInstallerMarker)) 'post-verification installer replacement never executes'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $fixture.AppRoot 'active.json.tmp'))) 'rejection or success leaves no uncommitted pointer sidecar'
    } finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch { }
            $process.Dispose()
        }
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Production mutation caught: creating/checking the stage by pathname and allowing directory substitution before the first staged leaf write.
Invoke-CcodTest 'activation pins the stage directory before any verified leaf write' {
    $fixture = New-CcodActivationPayloadFixture
    $libraryRoot = Join-Path $fixture.AppRoot 'activation-library'
    $outside = Join-Path $fixture.AppRoot 'outside-stage-target'
    $libraryPath = Join-Path $libraryRoot 'ActivationFunctions.psm1'
    $module = $null
    $breakpoint = $null
    $seal = $null
    $attack = [pscustomobject]@{ Attempted=$false; Outcome='not-run'; Stage=$null; Captured=$null }
    try {
        [IO.Directory]::CreateDirectory($libraryRoot) | Out-Null
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'outside-sentinel.txt'),'outside-original',[Text.UTF8Encoding]::new($false))
        $tokens = $null; $parseErrors = $null
        $activationAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'),[ref]$tokens,[ref]$parseErrors)
        Assert-CcodEqual 0 @($parseErrors).Count 'activation function library source parses before race fixture extraction'
        $definitions = @($activationAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text })
        Assert-CcodTrue ($definitions.Count -gt 10) 'activation race fixture extracts the real production function set'
        [IO.File]::WriteAllText($libraryPath,(($definitions -join "`r`n`r`n")+"`r`n"),[Text.UTF8Encoding]::new($false))
        $module = Import-Module $libraryPath -Force -PassThru
        $libraryLines = [IO.File]::ReadAllLines($libraryPath,[Text.UTF8Encoding]::new($false))
        $barrierLines = @()
        for ($index=0;$index-lt$libraryLines.Length;$index++) {
            if ($libraryLines[$index] -cmatch '^\s*foreach \(\$snapshot in @\(\$snapshots\)') { $barrierLines += ($index + 1) }
        }
        Assert-CcodEqual 1 $barrierLines.Count 'activation stage write barrier is unique'
        $appRoot = $fixture.AppRoot
        $attackAction = {
            if ($attack.Attempted) { return }
            $attack.Attempted = $true
            try {
                $stages = @(Get-ChildItem -LiteralPath $appRoot -Directory -Force | Where-Object { $_.Name -cmatch '^\.activation-payload-stage-[0-9a-f]{32}$' })
                if ($stages.Count -ne 1) { throw "expected one stage; found $($stages.Count)" }
                $attack.Stage = [IO.Path]::GetFullPath($stages[0].FullName)
                $expectedPrefix = [IO.Path]::GetFullPath($appRoot).TrimEnd('\') + '\'
                if (-not $attack.Stage.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'stage escaped fixture app root' }
                $attack.Captured = $attack.Stage + '.captured'
                [IO.Directory]::Move($attack.Stage,$attack.Captured)
                New-Item -ItemType Junction -Path $attack.Stage -Target $outside | Out-Null
                $attack.Outcome = 'substituted'
            } catch { $attack.Outcome = 'blocked' }
        }.GetNewClosure()
        $breakpoint = Set-PSBreakpoint -Script $libraryPath -Line $barrierLines[0] -Action $attackAction
        $caught = $null
        try {
            $seal = & $module {
                param($AppRoot,$PayloadRoot,$ManifestSha)
                New-CcodActivationPayloadSeal -AppRoot $AppRoot -Root $PayloadRoot -Version '2.5.22' -ExpectedManifestSha256 $ManifestSha
            } $fixture.AppRoot $fixture.PayloadRoot $fixture.ManifestSha256
        } catch { $caught = $_ }

        Assert-CcodEqual 'blocked' $attack.Outcome 'stage directory substitution is blocked while the write boundary is pinned'
        Assert-CcodTrue ($null -eq $caught -and $null -ne $seal) 'blocked substitution leaves the original verified stage usable'
        Assert-CcodEqual 'outside-original' ([IO.File]::ReadAllText((Join-Path $outside 'outside-sentinel.txt'),[Text.UTF8Encoding]::new($false))) 'stage race cannot alter the outside sentinel'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $outside -File -Force -Recurse).Count 'stage race cannot redirect any verified leaf outside'
    } finally {
        if ($null -ne $breakpoint) { Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue }
        if ($null -ne $seal -and $null -ne $module) { try { & $module { param($Value) Close-CcodActivationPayloadSeal -Seal $Value } $seal } catch { } }
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if ($null -ne $attack.Stage -and (Test-Path -LiteralPath $attack.Stage)) {
            $stageItem = Get-Item -LiteralPath $attack.Stage -Force
            if (($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete($attack.Stage) }
        }
        foreach ($path in @($attack.Captured,$fixture.AppRoot)) { if ($null -ne $path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}

Invoke-CcodTest 'activation accepts a compile-bound installer manifest hash before payload verification' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-hash-interface-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $activationId = '77777777-6666-5555-4444-333333333333'
        $stdoutPath = Join-Path $root 'stdout.txt'
        $stderrPath = Join-Path $root 'stderr.txt'
        $argumentLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -AppRoot "{1}" -InstallRoot "{1}" -PayloadRoot "{1}\payload\2.5.22" -ExpectedVersion "2.5.22" -ExpectedPayloadManifestSha256 "{2}" -ActivationId "{3}" -ValidateReceiptOnly' -f (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'),$root,('0' * 64),$activationId
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru
        try { $exitCode = [int]$process.ExitCode } finally { $process.Dispose() }
        $output = [IO.File]::ReadAllText($stdoutPath) + [IO.File]::ReadAllText($stderrPath)
        Assert-CcodEqual 3 $exitCode 'missing payload reaches the bounded verifier contract after accepting the manifest hash parameter'
        Assert-CcodTrue ($output -cnotmatch 'parameter name .ExpectedPayloadManifestSha256') 'compile-bound hash is a real activation parameter'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'activation rejects a changed payload module before any payload code executes' {
    $fixture = New-CcodActivationPayloadFixture
    try {
        $marker = Join-Path $fixture.AppRoot 'payload-module-executed.txt'
        $modulePath = Join-Path $fixture.PayloadRoot 'src\persistence\modules\InstallLifecycle.psm1'
        $markerLiteral = $marker.Replace("'","''")
        [IO.File]::WriteAllText($modulePath,"[IO.File]::WriteAllText('$markerLiteral','executed'); function Get-CcodLifecyclePayloadManifestFiles { @() }",[Text.UTF8Encoding]::new($false))

        $result = Invoke-CcodActivationVerifierFixture -Fixture $fixture -ExpectedManifestSha256 $fixture.ManifestSha256

        Assert-CcodEqual 3 $result.ExitCode 'payload hash mismatch is a bounded verification failure'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $marker)) 'unverified payload module code never executes'
        Assert-CcodTrue ($result.Output -cmatch 'CCOD_INSTALL_FILE_HASH_MISMATCH|CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID') 'failure retains a stable payload verification code'
    } finally {
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force }
    }
}

Invoke-CcodTest 'activation distinguishes a valid payload from a bad compile-bound manifest hash' {
    $fixture = New-CcodActivationPayloadFixture
    try {
        $valid = Invoke-CcodActivationVerifierFixture -Fixture $fixture -ExpectedManifestSha256 $fixture.ManifestSha256
        Assert-CcodEqual 3 $valid.ExitCode 'valid payload advances to bounded receipt verification'
        Assert-CcodTrue ($valid.Output -cmatch 'CCOD_ACTIVATION_RECEIPT_MISSING') 'valid payload reaches the receipt boundary after independent verification'
        $invalid = Invoke-CcodActivationVerifierFixture -Fixture $fixture -ExpectedManifestSha256 ('0' * 64)
        Assert-CcodEqual 3 $invalid.ExitCode 'bad compile-bound manifest hash fails verification'
        Assert-CcodTrue ($invalid.Output -cmatch 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID') 'bad manifest hash retains the stable payload code'
    } finally {
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force }
    }
}

Invoke-CcodTest 'activation requires the exact versioned payload root' {
    $fixture = New-CcodActivationPayloadFixture
    try {
        $wrongRoot = Join-Path $fixture.AppRoot 'payload\other'
        [IO.Directory]::CreateDirectory($wrongRoot) | Out-Null
        $result = Invoke-CcodActivationVerifierFixture -Fixture $fixture -ExpectedManifestSha256 $fixture.ManifestSha256 -PayloadRoot $wrongRoot
        Assert-CcodEqual 3 $result.ExitCode 'wrong version directory fails before receipt processing'
        Assert-CcodTrue ($result.Output -cmatch 'CCOD_INSTALL_PAYLOAD_PATH_INVALID') 'wrong payload root retains a stable path code'
    } finally {
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force }
    }
}

Invoke-CcodTest 'activation rejects a reparse payload ancestor' {
    $fixture = New-CcodActivationPayloadFixture
    $targetRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-payload-target-' + [guid]::NewGuid().ToString('N'))
    try {
        $sourceVersion = $fixture.PayloadRoot
        [IO.Directory]::CreateDirectory($targetRoot) | Out-Null
        Move-Item -LiteralPath $sourceVersion -Destination (Join-Path $targetRoot '2.5.22')
        Remove-Item -LiteralPath (Join-Path $fixture.AppRoot 'payload') -Force
        New-Item -ItemType Junction -Path (Join-Path $fixture.AppRoot 'payload') -Target $targetRoot | Out-Null
        $result = Invoke-CcodActivationVerifierFixture -Fixture $fixture -ExpectedManifestSha256 $fixture.ManifestSha256
        Assert-CcodEqual 3 $result.ExitCode 'payload junction fails before receipt processing'
        Assert-CcodTrue ($result.Output -cmatch 'CCOD_INSTALL_SOURCE_REPARSE') 'payload junction retains the reparse support code'
    } finally {
        $junction = Join-Path $fixture.AppRoot 'payload'
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force }
        if (Test-Path -LiteralPath $targetRoot) { Remove-Item -LiteralPath $targetRoot -Recurse -Force }
    }
}

Invoke-CcodTest 'activation rejects an unlisted nested payload junction' {
    $fixture = New-CcodActivationPayloadFixture
    $targetRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-nested-target-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($targetRoot) | Out-Null
        $junction = Join-Path $fixture.PayloadRoot 'unlisted-junction'
        New-Item -ItemType Junction -Path $junction -Target $targetRoot | Out-Null
        $result = Invoke-CcodActivationVerifierFixture -Fixture $fixture -ExpectedManifestSha256 $fixture.ManifestSha256
        Assert-CcodEqual 3 $result.ExitCode 'nested payload junction fails before receipt processing'
        Assert-CcodTrue ($result.Output -cmatch 'CCOD_INSTALL_SOURCE_REPARSE') 'nested payload junction retains the reparse support code'
    } finally {
        $junction = Join-Path $fixture.PayloadRoot 'unlisted-junction'
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        if (Test-Path -LiteralPath $fixture.AppRoot) { Remove-Item -LiteralPath $fixture.AppRoot -Recurse -Force }
        if (Test-Path -LiteralPath $targetRoot) { Remove-Item -LiteralPath $targetRoot -Recurse -Force }
    }
}

Invoke-CcodTest 'Inno compile refuses an implicit installer payload source' {
    $compile = Invoke-CcodInnoPayloadCompileFixture
    try {
        Assert-CcodTrue ($compile.ExitCode -ne 0) 'setup compilation fails without an explicit sealed installer package contract'
        Assert-CcodTrue ($compile.Output -cmatch 'InstallerPackagePath') 'compiler identifies the missing sealed package define'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $compile.SetupPath)) 'missing payload define produces no setup artifact'
    } finally {
        if (Test-Path -LiteralPath $compile.Root) { Remove-Item -LiteralPath $compile.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'Inno compile packages the explicit manifest-bound installer payload' {
    $compile = Invoke-CcodInnoPayloadCompileFixture -IncludePayloadDefines
    try {
        Assert-CcodEqual 0 $compile.ExitCode "explicit setup payload contract compiles: $($compile.Output)"
        Assert-CcodTrue (Test-Path -LiteralPath $compile.SetupPath -PathType Leaf) 'explicit payload compile produces the setup artifact'
        Assert-CcodTrue ($compile.GeneratedSource -cmatch 'procedure AddCcodExpectedSetupDirectories' -and $compile.GeneratedSource -cnotmatch 'Directories\.Add') 'compiler input contains an explicit empty destination inventory procedure'
        Assert-CcodTrue ($compile.GeneratedSource -cnotmatch 'CCOD_INSTALLER_DESTINATION_INVENTORY' -and $compile.GeneratedSource -cnotmatch '(?m)^\s*#\s*(?:include\b|\+)') 'compiler input contains neither the marker nor an external include'
        Assert-CcodTrue (-not [IO.File]::Exists($compile.GeneratedPath)) 'payload compile cleans its generated compiler input'
        Assert-CcodTrue ($compile.Output -cmatch 'installer-package\.zip' -and $compile.Output -cmatch 'installer-package\.manifest\.json' -and $compile.Output -cmatch 'Activate-CcodRemoteFix\.ps1') 'compiler input trace contains only the sealed package manifest and bootstrap inputs'
    } finally {
        if (Test-Path -LiteralPath $compile.Root) { Remove-Item -LiteralPath $compile.Root -Recurse -Force }
    }
}

# Production mutation caught: trusting ISCC exit zero and a newly computed sidecar without inspecting the final PE contract.
Invoke-CcodTest 'compiled Setup independently binds PE version commit package manifest and bootstrap hashes' {
    $modulePath = Join-Path $repositoryRoot 'build\SetupArtifact.psm1'
    Assert-CcodTrue (Test-Path -LiteralPath $modulePath -PathType Leaf) 'independent Setup artifact validator exists'
    Import-Module $modulePath -Force
    $compile = Invoke-CcodInnoPayloadCompileFixture -IncludePayloadDefines
    try {
        $validated = Test-CcodSetupArtifact -SetupPath $compile.SetupPath -ExpectedVersion '2.5.21' -ExpectedGitCommit $compile.SetupGitCommit -ExpectedPackageSha256 $compile.PackageSha256 -ExpectedPackageManifestSha256 $compile.PackageManifestSha256 -ExpectedActivationBootstrapSha256 $compile.ActivationBootstrapSha256
        Assert-CcodEqual $true ([bool]$validated.Valid) 'real ISCC Setup PE satisfies the independent version and payload contract'
        Assert-CcodEqual '2.5.21.0' ([string]$validated.FileVersion) 'Setup PE FileVersion is exact'
        Assert-CcodEqual $compile.PackageManifestSha256 ([string]$validated.PackageManifestSha256) 'Setup PE ProductVersion and description bind the full package manifest hash'
        Assert-CcodThrows {
            Test-CcodSetupArtifact -SetupPath $compile.SetupPath -ExpectedVersion '2.5.21' -ExpectedGitCommit $compile.SetupGitCommit -ExpectedPackageSha256 ('0' * 64) -ExpectedPackageManifestSha256 $compile.PackageManifestSha256 -ExpectedActivationBootstrapSha256 $compile.ActivationBootstrapSha256 | Out-Null
        } 'CCOD_SETUP_PAYLOAD_BINDING_INVALID'
    } finally {
        if (Test-Path -LiteralPath $compile.Root) { Remove-Item -LiteralPath $compile.Root -Recurse -Force }
    }
}

# Production mutation caught: compiled Setup metadata looks safe while CurStepChanged skips its runtime package hash/lock barrier.
Invoke-CcodTest 'compiled production Setup rejects a wrong package hash before activation and product state' {
    $fixture=Invoke-CcodInnoPayloadCompileFixture -IncludePayloadDefines -BindWrongPackageHash -UseInertActivationMarker
    $process=$null
    try {
        Assert-CcodEqual 0 $fixture.ExitCode "wrong-hash production Setup fixture compiles: $($fixture.Output)"
        Assert-CcodTrue (Test-Path -LiteralPath $fixture.SetupPath -PathType Leaf) 'wrong-hash compiled Setup exists'
        Assert-CcodEqual ('0'*64) ([string]$fixture.BoundPackageSha256) 'fixture binds the deliberate wrong package hash'
        Assert-CcodEqual ('0'*64) ([string][Diagnostics.FileVersionInfo]::GetVersionInfo($fixture.SetupPath).LegalCopyright).Trim() 'compiled PE independently retains the wrong expected package hash'
        $realProductRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
        $productStateBefore=Get-CcodReadOnlyProductTreeSnapshot -Root $realProductRoot
        $appRoot=Join-Path $fixture.Root 'forbidden-app-output'
        $logPath=Join-Path $fixture.Root 'executed-setup.log'
        $arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',("/DIR=$appRoot"),("/LOG=$logPath"))
        $startInfo=[Diagnostics.ProcessStartInfo]::new();$startInfo.FileName=$fixture.SetupPath;$startInfo.Arguments=(($arguments|ForEach-Object{'"'+([string]$_).Replace('"','\"')+'"'})-join' ');$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
        $process=[Diagnostics.Process]::new();$process.StartInfo=$startInfo
        Assert-CcodTrue $process.Start() 'wrong-hash compiled Setup starts'
        Assert-CcodTrue $process.WaitForExit(20000) 'wrong-hash compiled Setup exits within the pre-activation bound'
        $productStateAfter=Get-CcodReadOnlyProductTreeSnapshot -Root $realProductRoot
        Assert-CcodTrue (Test-Path -LiteralPath $logPath -PathType Leaf) 'executed Setup emits its isolated runtime log'
        $log=[IO.File]::ReadAllText($logPath,[Text.UTF8Encoding]::new($false))
        Assert-CcodTrue ([int]$process.ExitCode-ne0) "wrong-hash compiled Setup fails closed: exit=$([int]$process.ExitCode) log=$($log.Substring([Math]::Max(0,$log.Length-1000)))"
        Assert-CcodTrue ($log-cmatch 'CCOD_SETUP_INPUT_BINDING_INVALID') 'runtime CurStepChanged reports the package hash/lock barrier failure'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $fixture.ActivationMarker)) 'temporary activation bootstrap never executes'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $appRoot)) 'CreateAppDir=no leaves no app product output'
        Assert-CcodTrue ($log.IndexOf($realProductRoot,[StringComparison]::OrdinalIgnoreCase)-lt0) 'failure log never reaches the real LocalAppData product root'
        Assert-CcodEqual ($productStateBefore|ConvertTo-Json -Depth 8 -Compress) ($productStateAfter|ConvertTo-Json -Depth 8 -Compress) 'actual LocalAppData product tree is byte-and-metadata unchanged'
    } finally {
        if($null-ne$process){try{if(-not$process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}catch{};$process.Dispose()}
        if(Test-Path -LiteralPath $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

# Production mutation caught: accepting self-consistent but false Setup build-input hashes without comparing canonical files.
Invoke-CcodTest 'Setup provenance rejects self-consistent wrong canonical build input hashes' {
    Import-Module (Join-Path $repositoryRoot 'build\SetupArtifact.psm1') -Force
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-setup-provenance-inputs-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $template = Join-Path $root 'CodexControlOtherDevices.iss'
        $inventory = Join-Path $root 'InstallerDestinationInventory.iss'
        $compiler = Join-Path $root 'ISCC.exe'
        $payload = Join-Path $root 'installer-payload.manifest.json'
        $provenance = Join-Path $root 'setup-provenance.json'
        [IO.File]::WriteAllText($template,'canonical-template',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($inventory,'canonical-inventory',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllBytes($compiler,[byte[]](1,2,3,4,5,6,7,8))
        $payloadRecord = [ordered]@{schemaVersion=1;projectVersion='2.5.22';files=@([ordered]@{path='package.json';length=[int64]1;sha256=('a'*64)})}
        [IO.File]::WriteAllText($payload,($payloadRecord|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $payloadHash = Get-CcodTestFileSha256 -Path $payload
        $commit = 'b' * 40
        $timestamp = '2026-08-28T00:00:00.0000000Z'
        $record = [ordered]@{
            schemaVersion=1;product='CodexRemote-fix';version='2.5.22';gitCommit=$commit;buildTimestampUtc=$timestamp
            payloadManifest=[ordered]@{name='installer-payload.manifest.json';length=[int64](Get-Item -LiteralPath $payload).Length;sha256=$payloadHash;fileCount=1}
            buildInputs=[ordered]@{innoTemplateSha256=('1'*64);destinationInventorySha256=('2'*64);compilerSha256=('3'*64);compilerFileVersion='0.0.0.0'}
            peContract=[ordered]@{fileVersion='2.5.22.0';productVersion='2.5.22.0';productName='CodexRemote-fix';fileDescription='CCODSETUP 2.5.22';companyName=$commit;legalCopyright=$payloadHash}
        }
        [IO.File]::WriteAllText($provenance,(($record|ConvertTo-Json -Depth 8)+"`n"),[Text.UTF8Encoding]::new($false))

        Assert-CcodThrows {
            $validator = Get-Command Test-CcodSetupBuildProvenance
            if ($validator.Parameters.ContainsKey('InnoTemplatePath')) {
                Test-CcodSetupBuildProvenance -ProvenancePath $provenance -ExpectedVersion '2.5.22' -ExpectedGitCommit $commit -ExpectedPayloadManifestSha256 $payloadHash -ExpectedBuildTimestampUtc $timestamp -InnoTemplatePath $template -DestinationInventoryPath $inventory -CompilerPath $compiler -PayloadManifestPath $payload | Out-Null
            } else {
                Test-CcodSetupBuildProvenance -ProvenancePath $provenance -ExpectedVersion '2.5.22' -ExpectedGitCommit $commit -ExpectedPayloadManifestSha256 $payloadHash -ExpectedBuildTimestampUtc $timestamp | Out-Null
            }
        } 'CCOD_SETUP_PROVENANCE_INVALID'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

# Production mutation caught: schema-two provenance accepts cosmetic nested evidence not bound to the actual inputs.
Invoke-CcodTest 'sealed Setup provenance rejects every field type name length count hash and property-order mutation' {
    Import-Module (Join-Path $repositoryRoot 'build\SetupArtifact.psm1') -Force
    $fixture=Invoke-CcodInnoPayloadCompileFixture -IncludePayloadDefines
    try {
        Assert-CcodEqual 0 $fixture.ExitCode "sealed provenance fixture compiles: $($fixture.Output)"
        $provenance=Join-Path $fixture.Root 'sealed-setup-provenance.json'
        $timestamp='2030-02-03T04:05:06.0000000Z'
        $created=New-CcodSealedSetupBuildProvenance -Version '2.5.21' -GitCommit $fixture.SetupGitCommit -BuildTimestampUtc $timestamp -PackagePath $fixture.PackagePath -PackageManifestPath $fixture.PackageManifestPath -ActivationBootstrapPath $fixture.ActivationBootstrapPath -InnoTemplatePath $fixture.TemplatePath -DestinationInventoryPath $fixture.InventoryPath -CompilerPath $fixture.CompilerPath -OutputPath $provenance
        $arguments=@{ExpectedVersion='2.5.21';ExpectedGitCommit=$fixture.SetupGitCommit;ExpectedPackageSha256=$fixture.PackageSha256;ExpectedPackageManifestSha256=$fixture.PackageManifestSha256;ExpectedActivationBootstrapSha256=$fixture.ActivationBootstrapSha256;ExpectedBuildTimestampUtc=$timestamp;PackagePath=$fixture.PackagePath;PackageManifestPath=$fixture.PackageManifestPath;ActivationBootstrapPath=$fixture.ActivationBootstrapPath;InnoTemplatePath=$fixture.TemplatePath;DestinationInventoryPath=$fixture.InventoryPath;CompilerPath=$fixture.CompilerPath}
        $valid=Test-CcodSealedSetupBuildProvenance -ProvenancePath $provenance @arguments
        Assert-CcodEqual 2 ([int]$valid.schemaVersion) 'canonical schema-two provenance validates'
        $mutations=@(
            [pscustomobject]@{Name='top-level-order';Apply={param($r)$copy=[ordered]@{product=$r.product;schemaVersion=$r.schemaVersion;version=$r.version;gitCommit=$r.gitCommit;buildTimestampUtc=$r.buildTimestampUtc;installerPackage=$r.installerPackage;installerPackageManifest=$r.installerPackageManifest;activationBootstrap=$r.activationBootstrap;buildInputs=$r.buildInputs;peContract=$r.peContract};return [pscustomobject]$copy}},
            [pscustomobject]@{Name='schema-type';Apply={param($r)$r.schemaVersion='2';$r}},
            [pscustomobject]@{Name='version-type';Apply={param($r)$r.version=2521;$r}},
            [pscustomobject]@{Name='commit';Apply={param($r)$r.gitCommit='e'*40;$r}},
            [pscustomobject]@{Name='package-order';Apply={param($r)$r.installerPackage=[pscustomobject][ordered]@{sha256=$r.installerPackage.sha256;name=$r.installerPackage.name;length=$r.installerPackage.length};$r}},
            [pscustomobject]@{Name='package-name';Apply={param($r)$r.installerPackage.name='renamed.zip';$r}},
            [pscustomobject]@{Name='package-length';Apply={param($r)$r.installerPackage.length=[long]$r.installerPackage.length+1;$r}},
            [pscustomobject]@{Name='package-length-type';Apply={param($r)$r.installerPackage.length=[string]$r.installerPackage.length;$r}},
            [pscustomobject]@{Name='manifest-order';Apply={param($r)$r.installerPackageManifest=[pscustomobject][ordered]@{name=$r.installerPackageManifest.name;sha256=$r.installerPackageManifest.sha256;length=$r.installerPackageManifest.length;fileCount=$r.installerPackageManifest.fileCount;payloadManifestSha256=$r.installerPackageManifest.payloadManifestSha256};$r}},
            [pscustomobject]@{Name='manifest-name';Apply={param($r)$r.installerPackageManifest.name='renamed.json';$r}},
            [pscustomobject]@{Name='manifest-length';Apply={param($r)$r.installerPackageManifest.length=[long]$r.installerPackageManifest.length+1;$r}},
            [pscustomobject]@{Name='file-count';Apply={param($r)$r.installerPackageManifest.fileCount=[int]$r.installerPackageManifest.fileCount+1;$r}},
            [pscustomobject]@{Name='file-count-type';Apply={param($r)$r.installerPackageManifest.fileCount=[string]$r.installerPackageManifest.fileCount;$r}},
            [pscustomobject]@{Name='payload-manifest-sha';Apply={param($r)$r.installerPackageManifest.payloadManifestSha256='0'*64;$r}},
            [pscustomobject]@{Name='bootstrap-order';Apply={param($r)$r.activationBootstrap=[pscustomobject][ordered]@{length=$r.activationBootstrap.length;name=$r.activationBootstrap.name;sha256=$r.activationBootstrap.sha256};$r}},
            [pscustomobject]@{Name='bootstrap-name';Apply={param($r)$r.activationBootstrap.name='stale.ps1';$r}},
            [pscustomobject]@{Name='bootstrap-length';Apply={param($r)$r.activationBootstrap.length=[long]$r.activationBootstrap.length+1;$r}},
            [pscustomobject]@{Name='build-input-order';Apply={param($r)$r.buildInputs=[pscustomobject][ordered]@{compilerSha256=$r.buildInputs.compilerSha256;innoTemplateSha256=$r.buildInputs.innoTemplateSha256;destinationInventorySha256=$r.buildInputs.destinationInventorySha256;compilerFileVersion=$r.buildInputs.compilerFileVersion};$r}},
            [pscustomobject]@{Name='template-hash';Apply={param($r)$r.buildInputs.innoTemplateSha256='1'*64;$r}},
            [pscustomobject]@{Name='inventory-hash';Apply={param($r)$r.buildInputs.destinationInventorySha256='2'*64;$r}},
            [pscustomobject]@{Name='compiler-hash';Apply={param($r)$r.buildInputs.compilerSha256='3'*64;$r}},
            [pscustomobject]@{Name='compiler-version';Apply={param($r)$r.buildInputs.compilerFileVersion='9.9.9.9';$r}},
            [pscustomobject]@{Name='pe-order';Apply={param($r)$r.peContract=[pscustomobject][ordered]@{legalCopyright=$r.peContract.legalCopyright;fileVersion=$r.peContract.fileVersion;packageManifestFirst=$r.peContract.packageManifestFirst;packageManifestLast=$r.peContract.packageManifestLast;bootstrapFirst=$r.peContract.bootstrapFirst;bootstrapLast=$r.peContract.bootstrapLast;companyName=$r.peContract.companyName};$r}},
            [pscustomobject]@{Name='nested-extra';Apply={param($r)$r.activationBootstrap|Add-Member attacker 'x';$r}}
        )
        foreach($mutation in $mutations){
            $record=([IO.File]::ReadAllText($provenance,[Text.UTF8Encoding]::new($false))|ConvertFrom-Json)
            $record=&$mutation.Apply $record
            $mutated=Join-Path $fixture.Root ("provenance-$($mutation.Name).json")
            [IO.File]::WriteAllText($mutated,(($record|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
            $failure=$null
            try{Test-CcodSealedSetupBuildProvenance -ProvenancePath $mutated @arguments|Out-Null}catch{$failure=$_}
            Assert-CcodTrue ($null-ne$failure) "provenance mutation is rejected: $($mutation.Name)"
            Assert-CcodTrue ($failure.FullyQualifiedErrorId-like'CCOD_SETUP_PROVENANCE_INVALID*') "provenance mutation has the bounded code: $($mutation.Name)"
        }
        $rawProvenance=[IO.File]::ReadAllText($provenance,[Text.UTF8Encoding]::new($false))
        $duplicatePatterns=@(
            [pscustomobject]@{Name='top';Pattern='(?s)^\s*\{\s*(?<member>"schemaVersion"\s*:\s*2)'},
            [pscustomobject]@{Name='installerPackage';Pattern='(?s)"installerPackage"\s*:\s*\{\s*(?<member>"name"\s*:\s*"[^"]+")'},
            [pscustomobject]@{Name='installerPackageManifest';Pattern='(?s)"installerPackageManifest"\s*:\s*\{\s*(?<member>"name"\s*:\s*"[^"]+")'},
            [pscustomobject]@{Name='activationBootstrap';Pattern='(?s)"activationBootstrap"\s*:\s*\{\s*(?<member>"name"\s*:\s*"[^"]+")'},
            [pscustomobject]@{Name='buildInputs';Pattern='(?s)"buildInputs"\s*:\s*\{\s*(?<member>"innoTemplateSha256"\s*:\s*"[^"]+")'},
            [pscustomobject]@{Name='peContract';Pattern='(?s)"peContract"\s*:\s*\{\s*(?<member>"fileVersion"\s*:\s*"[^"]+")'}
        )
        foreach($duplicate in $duplicatePatterns){
            $match=[regex]::Match($rawProvenance,$duplicate.Pattern)
            Assert-CcodTrue ($match.Success-and$match.Groups['member'].Success) "duplicate mutation locates object: $($duplicate.Name)"
            $member=$match.Groups['member'].Value
            $duplicateRaw=$rawProvenance.Insert($match.Groups['member'].Index+$match.Groups['member'].Length,(','+$member))
            $mutated=Join-Path $fixture.Root ("provenance-duplicate-$($duplicate.Name).json")
            [IO.File]::WriteAllText($mutated,$duplicateRaw,[Text.UTF8Encoding]::new($false))
            $failure=$null
            try{Test-CcodSealedSetupBuildProvenance -ProvenancePath $mutated @arguments|Out-Null}catch{$failure=$_}
            Assert-CcodTrue ($null-ne$failure) "raw duplicate provenance member is rejected: $($duplicate.Name)"
            Assert-CcodTrue ($failure.FullyQualifiedErrorId-like'CCOD_SETUP_PROVENANCE_INVALID*') "raw duplicate provenance member has bounded code: $($duplicate.Name)"
        }
    } finally {
        if(Test-Path -LiteralPath $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

# Production mutation caught: cleaning payload stage/inventory only after a successful Setup build.
Invoke-CcodTest 'build temporary Setup inputs are cleaned from the exact finally boundary after failure' {
    . (Join-Path $repositoryRoot 'build\build.ps1') -Library
    Assert-CcodTrue ($null -ne (Get-Command Invoke-CcodBuildTemporarySetupScope -ErrorAction SilentlyContinue)) 'build exposes its production temporary Setup scope'
    $buildRoot = Join-Path $repositoryRoot 'build'
    $payloadStage = Join-Path $buildRoot ('.installer-payload-stage-' + [guid]::NewGuid().ToString('N'))
    $inventory = Join-Path $buildRoot ('.installer-destination-inventory-' + [guid]::NewGuid().ToString('N') + '.iss')
    $fixturePayloadStage = $payloadStage
    $fixtureInventory = $inventory
    Assert-CcodThrows {
        Invoke-CcodBuildTemporarySetupScope -BuildRoot $buildRoot -InstallerPayloadDirectory $fixturePayloadStage -DestinationInventoryPath $fixtureInventory -Action {
            param($PayloadStagePath,$InventoryPath)
            [IO.Directory]::CreateDirectory($PayloadStagePath) | Out-Null
            [IO.File]::WriteAllText((Join-Path $PayloadStagePath 'fixture.txt'),'fixture',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($InventoryPath,'fixture',[Text.UTF8Encoding]::new($false))
            throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('fixture failure'),'CCOD_BUILD_FIXTURE_FAILURE',[Management.Automation.ErrorCategory]::OperationStopped,$null)
        }
    } 'CCOD_BUILD_FIXTURE_FAILURE'
    Assert-CcodTrue (-not [IO.Directory]::Exists($payloadStage)) 'failed build leaves no installer payload stage'
    Assert-CcodTrue (-not [IO.File]::Exists($inventory)) 'failed build leaves no destination inventory'
}

Invoke-CcodTest 'Inno compile refuses a missing generated destination inventory' {
    $compile = Invoke-CcodInnoPayloadCompileFixture -IncludePayloadDefines -OmitDestinationInventory
    try {
        Assert-CcodTrue ($compile.ExitCode -ne 0) 'setup compilation fails before ISCC when the generated inventory is missing'
        Assert-CcodTrue ($compile.Output -cmatch 'destination inventory.*missing') 'generation identifies the missing destination inventory artifact'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $compile.SetupPath)) 'missing inventory define produces no setup artifact'
        Assert-CcodTrue (-not [IO.File]::Exists($compile.GeneratedPath)) 'missing inventory leaves no generated compiler input'
    } finally {
        if (Test-Path -LiteralPath $compile.Root) { Remove-Item -LiteralPath $compile.Root -Recurse -Force }
    }
}

<# Superseded by the sealed no-product-write Setup boundary in Task 3.
Invoke-CcodTest 'Inno exposes a pre-write payload-directory reparse gate' {
    $inno = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $helper = [regex]::Match($inno,'(?ms)^function IsSafeExistingPayloadDirectory\(.*?^end;')
    Assert-CcodTrue $helper.Success 'production Inno script exposes the directory predicate used before payload writes'
    $streamHelper = [regex]::Match($inno,'(?ms)^function HasOnlyDefaultDataStream\(.*?^end;')
    $leafHelper = [regex]::Match($inno,'(?ms)^function IsSafeExistingSetupLeaf\(.*?^end;')
    Assert-CcodTrue ($streamHelper.Success -and $leafHelper.Success) 'production Inno script exposes native stream and link-count predicates for existing leaves'
    $treeHelper = [regex]::Match($inno,'(?ms)^function IsSafeExistingSetupTree\(.*?^end;')
    Assert-CcodTrue $treeHelper.Success 'production Inno script exposes a recursive destination-tree predicate'
    $inventoryValidator = [regex]::Match($inno,'(?ms)^function AreCcodExpectedSetupDirectoriesSafe\(.*?^end;')
    Assert-CcodTrue $inventoryValidator.Success 'production Inno script exposes a generated destination-inventory validator'
    $pinBlockMatch = [regex]::Match($inno,'(?ms)^// CCOD_SETUP_PIN_BEGIN\s*$\r?\n(?<body>.*?)^// CCOD_SETUP_PIN_END\s*$')
    $pinBlock = if ($pinBlockMatch.Success) { $pinBlockMatch.Groups['body'].Value } else { @'
function PinCcodExistingSetupTree(const DirectoryName: String): Boolean;
begin
  Result := IsSafeExistingSetupTree(DirectoryName);
end;
procedure CloseCcodSetupPins();
begin
end;
'@ }
    Assert-CcodTrue ($inno -cmatch '(?m)^// CCOD_INSTALLER_DESTINATION_INVENTORY\s*$' -and $inno -cmatch '(?ms)^function PrepareToInstall\(var NeedsRestart: Boolean\): String;.*?AreCcodExpectedSetupDirectoriesSafe') 'PrepareToInstall consumes the generated inventory injected at the unique marker before file copy'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-inno-reparse-harness-' + [guid]::NewGuid().ToString('N'))
    try {
        $normal = Join-Path $root 'normal'
        $target = Join-Path $root 'target'
        $junction = Join-Path $root 'junction'
        $missing = Join-Path $root 'missing'
        $tree = Join-Path $root 'tree'
        $nested = Join-Path $tree 'src\escape'
        $fileDirectory = Join-Path $root 'file-as-directory'
        $expectedFileRoot = Join-Path $root 'expected-file-root'
        $expectedJunctionRoot = Join-Path $root 'expected-junction-root'
        $normalExpectedRoot = Join-Path $root 'normal-expected-root'
        $inventoryPayload = Join-Path $root 'inventory-payload'
        $hardLinkTree = Join-Path $root 'hardlink-tree'
        $outsideHardLink = Join-Path $root 'outside-hardlink-sentinel.txt'
        $hardLinkLeaf = Join-Path $hardLinkTree 'existing-leaf.txt'
        $fileWriteMarker = Join-Path $expectedFileRoot 'payload-write-marker.txt'
        $junctionWriteMarker = Join-Path $expectedJunctionRoot 'payload-write-marker.txt'
        $resultPath = Join-Path $root 'result.txt'
        $concurrentTarget = Join-Path $root 'concurrent-target'
        $concurrentMoved = Join-Path $root 'concurrent-target-moved'
        $concurrentOutside = Join-Path $root 'concurrent-outside'
        $attackScript = Join-Path $root 'Invoke-ConcurrentSubstitution.ps1'
        $attackResult = Join-Path $root 'concurrent-attack.txt'
        $pinWriteResult = Join-Path $root 'concurrent-write.txt'
        [IO.Directory]::CreateDirectory($normal) | Out-Null
        [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path $nested -Parent)) | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        New-Item -ItemType Junction -Path $nested -Target $target | Out-Null
        [IO.File]::WriteAllText($fileDirectory,'not a directory',[Text.UTF8Encoding]::new($false))
        [IO.Directory]::CreateDirectory((Join-Path $expectedFileRoot 'src')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $expectedFileRoot 'src\persistence'),'not a directory',[Text.UTF8Encoding]::new($false))
        [IO.Directory]::CreateDirectory((Join-Path $expectedJunctionRoot 'payload\2.5.22\src')) | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $expectedJunctionRoot 'payload\2.5.22\src\persistence') -Target $target | Out-Null
        [IO.Directory]::CreateDirectory($normalExpectedRoot) | Out-Null
        [IO.Directory]::CreateDirectory($hardLinkTree) | Out-Null
        [IO.File]::WriteAllText($outsideHardLink,'outside-original',[Text.UTF8Encoding]::new($false))
        New-Item -ItemType HardLink -Path $hardLinkLeaf -Target $outsideHardLink | Out-Null
        [IO.Directory]::CreateDirectory($concurrentTarget) | Out-Null
        [IO.Directory]::CreateDirectory($concurrentOutside) | Out-Null
        [IO.File]::WriteAllText((Join-Path $concurrentTarget 'payload.txt'),'target-original',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $concurrentOutside 'payload.txt'),'outside-original',[Text.UTF8Encoding]::new($false))
        $attackSource = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$Moved,[Parameter(Mandatory)][string]$Outside,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
try {
    Move-Item -LiteralPath $Target -Destination $Moved -ErrorAction Stop
    New-Item -ItemType Junction -Path $Target -Target $Outside -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText($ResultPath,'substituted',[Text.UTF8Encoding]::new($false))
} catch {
    [IO.File]::WriteAllText($ResultPath,'blocked',[Text.UTF8Encoding]::new($false))
}
'@
        [IO.File]::WriteAllText($attackScript,$attackSource,[Text.UTF8Encoding]::new($false))
        [IO.Directory]::CreateDirectory((Join-Path $inventoryPayload 'src\persistence\modules')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $inventoryPayload 'src\persistence\modules\InstallLifecycle.psm1'),'fixture',[Text.UTF8Encoding]::new($false))
        $inventoryPath = Join-Path $root 'InventoryFixture.iss'
        & (Join-Path $repositoryRoot 'tools\New-InstallerDestinationInventory.ps1') -RepositoryRoot $repositoryRoot -PayloadRoot $inventoryPayload -ProjectVersion '2.5.22' -InnoScriptPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -OutputPath $inventoryPath | Out-Null
        $inventorySource = [IO.File]::ReadAllText($inventoryPath,[Text.UTF8Encoding]::new($false))
        $harnessPath = Join-Path $root 'ReparseGate.iss'
        $harness = @"
[Setup]
AppName=ReparseGate
AppVersion=1.0.0
DefaultDirName={tmp}\ReparseGate
PrivilegesRequired=lowest
OutputDir=$($root.Replace('\','\\'))
OutputBaseFilename=ReparseGate
Uninstallable=no
[Code]
const
  CCOD_FILE_ATTRIBUTE_DIRECTORY = `$00000010;
  CCOD_FILE_ATTRIBUTE_REPARSE_POINT = `$00000400;
  CCOD_FILE_READ_ATTRIBUTES = `$00000080;
  CCOD_DELETE_ACCESS = `$00010000;
  CCOD_FILE_SHARE_READ = `$00000001;
  CCOD_FILE_SHARE_WRITE = `$00000002;
  CCOD_FILE_SHARE_DELETE = `$00000004;
  CCOD_OPEN_EXISTING = 3;
  CCOD_FILE_FLAG_OPEN_REPARSE_POINT = `$00200000;
  CCOD_FILE_FLAG_BACKUP_SEMANTICS = `$02000000;
  CCOD_INVALID_FILE_ATTRIBUTES = `$FFFFFFFF;
  CCOD_INVALID_HANDLE_VALUE = -1;
  CCOD_ERROR_HANDLE_EOF = 38;
type
  TCcodFileTime = record
    LowDateTime: Cardinal;
    HighDateTime: Cardinal;
  end;
  TCcodByHandleFileInformation = record
    FileAttributes: Cardinal;
    CreationTime: TCcodFileTime;
    LastAccessTime: TCcodFileTime;
    LastWriteTime: TCcodFileTime;
    VolumeSerialNumber: Cardinal;
    FileSizeHigh: Cardinal;
    FileSizeLow: Cardinal;
    NumberOfLinks: Cardinal;
    FileIndexHigh: Cardinal;
    FileIndexLow: Cardinal;
  end;
  TCcodFindStreamData = record
    StreamSize: Int64;
    StreamNameBuffer: array[0..591] of Byte;
  end;
function GetFileAttributesW(const FileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function CreateFileW(const FileName: String; DesiredAccess, ShareMode,
  SecurityAttributes, CreationDisposition, FlagsAndAttributes,
  TemplateFile: Cardinal): Integer;
  external 'CreateFileW@kernel32.dll stdcall';
function GetFileInformationByHandle(FileHandle: Integer;
  var Information: TCcodByHandleFileInformation): Boolean;
  external 'GetFileInformationByHandle@kernel32.dll stdcall';
function CloseHandle(Handle: Integer): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function FindFirstStreamW(const FileName: String; InfoLevel: Integer;
  var StreamData: TCcodFindStreamData; Flags: Cardinal): Integer;
  external 'FindFirstStreamW@kernel32.dll stdcall';
function FindNextStreamW(FindHandle: Integer;
  var StreamData: TCcodFindStreamData): Boolean;
  external 'FindNextStreamW@kernel32.dll stdcall';
function CcodFindClose(FindHandle: Integer): Boolean;
  external 'FindClose@kernel32.dll stdcall';
function GetLastError(): Cardinal;
  external 'GetLastError@kernel32.dll stdcall';
$($helper.Value)
$($streamHelper.Value)
$($leafHelper.Value)
$($treeHelper.Value)
$inventorySource
$($inventoryValidator.Value)
$pinBlock
function InitializeSetup(): Boolean;
var
  AttackResultCode: Integer;
  AttackParameters: String;
begin
  if AreCcodExpectedSetupDirectoriesSafe('$($expectedFileRoot.Replace("'","''"))') then
    SaveStringToFile('$($fileWriteMarker.Replace("'","''"))','unsafe write',False);
  if AreCcodExpectedSetupDirectoriesSafe('$($expectedJunctionRoot.Replace("'","''"))') then
    SaveStringToFile('$($junctionWriteMarker.Replace("'","''"))','unsafe write',False);
  if IsSafeExistingSetupTree('$($hardLinkTree.Replace("'","''"))') then
    SaveStringToFile('$($hardLinkLeaf.Replace("'","''"))','unsafe overwrite',False);
  if PinCcodExistingSetupTree('$($concurrentTarget.Replace("'","''"))') then
  begin
    AttackParameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      '$($attackScript.Replace("'","''"))' + '" -Target "' + '$($concurrentTarget.Replace("'","''"))' +
      '" -Moved "' + '$($concurrentMoved.Replace("'","''"))' + '" -Outside "' +
      '$($concurrentOutside.Replace("'","''"))' + '" -ResultPath "' + '$($attackResult.Replace("'","''"))' + '"';
    if (not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), AttackParameters,
      '', SW_HIDE, ewWaitUntilTerminated, AttackResultCode)) or (AttackResultCode <> 0) then
      SaveStringToFile('$($attackResult.Replace("'","''"))','attacker-failed',False);
    if SaveStringToFile('$((Join-Path $concurrentTarget 'payload.txt').Replace("'","''"))','setup-write',False) then
      SaveStringToFile('$($pinWriteResult.Replace("'","''"))','write-ok',False)
    else
      SaveStringToFile('$($pinWriteResult.Replace("'","''"))','write-failed',False);
    CloseCcodSetupPins();
  end
  else
    SaveStringToFile('$($pinWriteResult.Replace("'","''"))','pin-failed',False);
  if IsSafeExistingPayloadDirectory('$($normal.Replace("'","''"))') and
     IsSafeExistingPayloadDirectory('$($missing.Replace("'","''"))') and
     (not IsSafeExistingPayloadDirectory('$($junction.Replace("'","''"))')) and
     (not IsSafeExistingSetupTree('$($tree.Replace("'","''"))')) and
     (not IsSafeExistingSetupTree('$($fileDirectory.Replace("'","''"))')) and
     (not IsSafeExistingSetupTree('$($hardLinkTree.Replace("'","''"))')) and
     AreCcodExpectedSetupDirectoriesSafe('$($normalExpectedRoot.Replace("'","''"))') and
     (not AreCcodExpectedSetupDirectoriesSafe('$($expectedFileRoot.Replace("'","''"))')) and
     (not AreCcodExpectedSetupDirectoriesSafe('$($expectedJunctionRoot.Replace("'","''"))')) then
    SaveStringToFile('$($resultPath.Replace("'","''"))','pass',False);
  Result := False;
end;
procedure DeinitializeSetup();
begin
  CloseCcodSetupPins();
end;
"@
        [IO.File]::WriteAllText($harnessPath,$harness,[Text.UTF8Encoding]::new($false))
        $iscc = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
        $compileOutput = @(& $iscc $harnessPath 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE "reparse predicate harness compiles: $($compileOutput -join ' ')"
        $process = Start-Process -FilePath (Join-Path $root 'ReparseGate.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') -WindowStyle Hidden -Wait -PassThru
        try { $null = $process.ExitCode } finally { $process.Dispose() }
        Assert-CcodEqual 'pass' ([IO.File]::ReadAllText($resultPath,[Text.UTF8Encoding]::new($false))) 'production predicate rejects root/nested junctions and file-valued directory paths'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $fileWriteMarker)) 'nested file-as-directory is rejected before simulated payload writes'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $junctionWriteMarker)) 'nested junction is rejected before simulated payload writes'
        Assert-CcodEqual 'outside-original' ([IO.File]::ReadAllText($outsideHardLink,[Text.UTF8Encoding]::new($false))) 'hard-linked setup leaf is rejected before simulated outside overwrite'
        Assert-CcodEqual 'blocked' ([IO.File]::ReadAllText($attackResult,[Text.UTF8Encoding]::new($false))) 'concurrent directory substitution is blocked after Setup preflight'
        Assert-CcodEqual 'write-ok' ([IO.File]::ReadAllText($pinWriteResult,[Text.UTF8Encoding]::new($false))) 'retained pins still allow the legitimate Setup overwrite'
        Assert-CcodEqual 'outside-original' ([IO.File]::ReadAllText((Join-Path $concurrentOutside 'payload.txt'),[Text.UTF8Encoding]::new($false))) 'concurrent substitution cannot redirect Setup bytes to the outside sentinel'
        Assert-CcodEqual 'setup-write' ([IO.File]::ReadAllText((Join-Path $concurrentTarget 'payload.txt'),[Text.UTF8Encoding]::new($false))) 'simulated Setup write reaches the pinned destination identity'
    } finally {
        if (Test-Path -LiteralPath $concurrentTarget) {
            $concurrentItem = Get-Item -LiteralPath $concurrentTarget -Force
            if (($concurrentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete($concurrentTarget) }
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

#>

# Production mutation caught: hashing one temporary bootstrap and later executing replacement bytes from the same path.
Invoke-CcodTest 'temporary bootstrap lock makes the verified source bytes the executed bytes' {
    $inno = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    Assert-CcodTrue ($inno -cmatch '(?s)function LockCcodInput.*GetSHA256OfFile\(Path\).*CreateFileW\(Path, CCOD_GENERIC_READ, CCOD_FILE_SHARE_READ.*GetSHA256OfFile\(Path\)') 'Setup hashes locks and rehashes each temporary input'
    Assert-CcodTrue ($inno -cmatch '(?s)function GetCcodBootstrapParameters.*-File.*CcodBootstrapPath' -and $inno -cmatch '(?s)procedure CurStepChanged.*GetCcodBootstrapParameters.*Exec\(') 'Setup executes the exact locked temporary bootstrap path'
    Assert-CcodTrue ($inno -cmatch '(?s)procedure DeinitializeSetup\(\);.*CloseCcodInputHandles') 'Setup retains input locks through terminal validation'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-bootstrap-lock-' + [guid]::NewGuid().ToString('N'))
    $lock = $null
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $scriptPath = Join-Path $root 'ccod-activation-bootstrap.ps1'
        $marker = Join-Path $root 'executed.txt'
        [IO.File]::WriteAllText($scriptPath,"[IO.File]::WriteAllText('$($marker.Replace("'","''"))','original',[Text.UTF8Encoding]::new(`$false))",[Text.UTF8Encoding]::new($false))
        $expected = Get-CcodTestFileSha256 -Path $scriptPath
        $lock = [IO.File]::Open($scriptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        Assert-CcodEqual $expected (Get-CcodTestFileSha256 -Path $scriptPath) 'locked bootstrap bytes retain the verified hash'
        $replacementBlocked = $false
        try { [IO.File]::WriteAllText($scriptPath,"[IO.File]::WriteAllText('$($marker.Replace("'","''"))','replacement')",[Text.UTF8Encoding]::new($false)) } catch [IO.IOException] { $replacementBlocked = $true }
        Assert-CcodTrue $replacementBlocked 'replacement is blocked while the verified bootstrap handle is retained'
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath
        Assert-CcodEqual 0 $LASTEXITCODE 'locked verified bootstrap executes successfully'
        Assert-CcodEqual 'original' ([IO.File]::ReadAllText($marker,[Text.UTF8Encoding]::new($false))) 'the executed bytes are the original verified bytes'
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
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

Invoke-CcodTask5Test 'defender' 'Defender gate binds exact origins status clocks manifests and a redacted receipt' {
    . $defenderPath -Library;$fixture=New-CcodReleaseFixture
    try{
        Set-Content -LiteralPath $fixture.Installer -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`n" -NoNewline
        $clean=New-CcodTask5DefenderAdapterFixture;$receipt=Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin InternetDownload -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root 'internet.json') -Adapters $clean.Adapters
        $fields='schemaVersion,assetType,assetName,assetSha256,checksumName,checksumSha256,manifestName,manifestSha256,version,gitCommit,origin,workflowArtifactIdentity,zoneId,defenderServiceEnabled,antivirusEnabled,realTimeProtectionEnabled,defenderPlatformVersion,defenderEngineVersion,signatureVersion,signatureUpdatedAtUtc,scanStartedAtUtc,scanCompletedAtUtc,detectionCount,outcome,errorCode'
        Assert-CcodEqual $fields (($receipt.PSObject.Properties.Name)-join',') 'receipt exposes only the exact ordered schema';Assert-CcodEqual 'InternetDownload' $receipt.origin 'official download receipt is origin-bound';Assert-CcodEqual 3 $receipt.zoneId 'official download receipt binds actual ZoneId 3';Assert-CcodEqual $null $receipt.workflowArtifactIdentity 'official download receipt has no workflow identity';Assert-CcodEqual (Get-CcodTestFileSha256 $fixture.Installer) $receipt.assetSha256 'receipt binds exact candidate hash';Assert-CcodEqual (Get-CcodTestFileSha256 $fixture.Manifest) $receipt.manifestSha256 'receipt binds exact matching manifest hash';Assert-CcodTrue (-not(($receipt|ConvertTo-Json -Depth 12 -Compress).Contains($fixture.Root))) 'receipt contains no source path or raw output'
        $originalCandidate=[IO.File]::ReadAllBytes($fixture.Installer);$race=New-CcodTask5DefenderAdapterFixture;$race.Adapters.StartCustomScan={param($Path)$race.State.Calls.Add('Scan');$stream=[IO.File]::Open($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.WriteByte(255);$stream.Flush($true)}finally{$stream.Dispose()}}.GetNewClosure()
        try{Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin InternetDownload -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root 'identity-race.json') -Adapters $race.Adapters|Out-Null} 'CCOD_RELEASE_ASSET_HASH_MISMATCH';Assert-CcodTrue (-not($race.State.Calls-contains'Write')) 'post-scan candidate mutation blocks receipt write'}finally{[IO.File]::WriteAllBytes($fixture.Installer,$originalCandidate);Set-Content -LiteralPath $fixture.Installer -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`n" -NoNewline}
        Remove-Item -LiteralPath $fixture.Installer -Stream Zone.Identifier
        foreach($zone in @($null,2)){$case=New-CcodTask5DefenderAdapterFixture;$case.Adapters.GetZoneId={param($Path)$zone}.GetNewClosure();Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin InternetDownload -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root "zone-$zone.json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_ZONE_REQUIRED';Assert-CcodTrue (-not($case.State.Calls-contains'Scan')) 'invalid Zone blocks scan'}
        foreach($zoneShape in @([pscustomobject]@{Name='duplicate';Text="[ZoneTransfer]`r`nZoneId=3`r`nZoneId=3`r`n"},[pscustomobject]@{Name='mixed';Text="[ZoneTransfer]`r`nZoneId=3`r`nZoneId=2`r`n"})){Set-Content -LiteralPath $fixture.Installer -Stream Zone.Identifier -Value $zoneShape.Text -NoNewline;$case=New-CcodTask5DefenderAdapterFixture;Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin InternetDownload -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root "zone-$($zoneShape.Name).json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_ZONE_REQUIRED';Assert-CcodTrue (-not($case.State.Calls-contains'Scan')) "$($zoneShape.Name) ZoneId metadata blocks scan";Remove-Item -LiteralPath $fixture.Installer -Stream Zone.Identifier}
        $identity=New-CcodTask5WorkflowIdentity ('a'*40);$trusted=New-CcodTask5DefenderAdapterFixture;$trustedReceipt=Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root 'trusted.json') -Adapters $trusted.Adapters;Assert-CcodEqual $null $trustedReceipt.zoneId 'trusted workflow receipt never claims Internet Zone';Assert-CcodEqual ($identity|ConvertTo-Json -Compress) ($trustedReceipt.workflowArtifactIdentity|ConvertTo-Json -Compress) 'trusted receipt binds exact workflow artifact identity'
        Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root 'trusted-missing.json') -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters|Out-Null} 'CCOD_DEFENDER_ORIGIN_INVALID'
        Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin InternetDownload -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root 'internet-identity.json') -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters|Out-Null} 'CCOD_DEFENDER_ORIGIN_INVALID'
        foreach($field in @('provider','repository','runId','runAttempt','artifactId','artifactName','artifactDigest','gitCommit')){$bad=(($identity|ConvertTo-Json -Compress)|ConvertFrom-Json);if($field-in@('runId','runAttempt','artifactId')){$bad.$field=0}elseif($field-ceq'artifactDigest'){$bad.$field='sha256:bad'}elseif($field-ceq'gitCommit'){$bad.$field='b'*40}else{$bad.$field='foreign'};Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $bad -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root "trusted-$field.json") -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters|Out-Null} 'CCOD_DEFENDER_ORIGIN_INVALID'}
        foreach($mutation in @('Service','Antivirus','Realtime','Platform','Engine','Signature','SignatureMissing','SignatureStale','SignatureFuture')){$status=New-CcodTask5DefenderStatus;switch($mutation){'Service'{$status.AMServiceEnabled=$false};'Antivirus'{$status.AntivirusEnabled=$false};'Realtime'{$status.RealTimeProtectionEnabled=$false};'Platform'{$status.AMProductVersion=''};'Engine'{$status.AMEngineVersion=''};'Signature'{$status.AntivirusSignatureVersion=''};'SignatureMissing'{$status.AntivirusSignatureLastUpdated=$null};'SignatureStale'{$status.AntivirusSignatureLastUpdated=[datetime]::Parse('2030-01-30T04:05:05Z')};'SignatureFuture'{$status.AntivirusSignatureLastUpdated=[datetime]::Parse('2030-02-03T04:10:07Z')}};$case=New-CcodTask5DefenderAdapterFixture -Status $status;Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root "status-$mutation.json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_STATUS_INVALID';Assert-CcodTrue (-not($case.State.Calls-contains'Scan')) "$mutation blocks scan"}
        foreach($clock in @('Reverse','TooLong','Invalid')){$completed=if($clock-ceq'Reverse'){[datetime]::Parse('2030-02-03T04:05:05Z')}elseif($clock-ceq'TooLong'){[datetime]::Parse('2030-02-03T06:05:07Z')}else{'not-a-clock'};$case=New-CcodTask5DefenderAdapterFixture -Completed $completed;Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root "clock-$clock.json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_CLOCK_INVALID'}
        foreach($failure in @('Scan','Detection','Write')){$case=if($failure-ceq'Scan'){New-CcodTask5DefenderAdapterFixture -ScanThrows}elseif($failure-ceq'Detection'){New-CcodTask5DefenderAdapterFixture -Detects}else{New-CcodTask5DefenderAdapterFixture -WriteThrows};$error=if($failure-ceq'Scan'){'CCOD_DEFENDER_SCAN_FAILED'}elseif($failure-ceq'Detection'){'CCOD_DEFENDER_DETECTIONS_FOUND'}else{'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'};Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath (Join-Path $fixture.Root "failure-$failure.json") -Adapters $case.Adapters|Out-Null} $error}
        $command=Get-Command $defenderPath;Assert-CcodTrue (-not$command.Parameters.ContainsKey('ZoneId')) 'public tool exposes no Zone synthesis parameter'
    }finally{if(Test-Path $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force}}
}

Invoke-CcodTask5Test 'evidence' 'Defender default evidence writer is create-only and rejects unsafe targets before scan' {
    . $defenderPath -Library
    $fixture=New-CcodReleaseFixture
    $unsafeOutside=$null;$unsafeLink=$null
    try{
        $identity=New-CcodTask5WorkflowIdentity ('a'*40)
        $clean=New-CcodTask5DefenderAdapterFixture;$adapters=@{};foreach($key in @($clean.Adapters.Keys)){if([string]$key-cne'WriteReceipt'){$adapters[[string]$key]=$clean.Adapters[$key]}}
        $evidence=Join-Path $fixture.Root 'create-only-receipt.json'
        $receipt=Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath $evidence -Adapters $adapters
        Assert-CcodTrue (Test-Path -LiteralPath $evidence -PathType Leaf) 'default writer creates the requested regular evidence leaf'
        $persisted=[IO.File]::ReadAllText($evidence,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
        Assert-CcodEqual ($receipt|ConvertTo-Json -Depth 12 -Compress) ($persisted|ConvertTo-Json -Depth 12 -Compress) 'default writer persists only the returned canonical receipt'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $fixture.Root -Force|Where-Object{$_.Name-like'.ccod-defender-receipt-*'}).Count 'default writer leaves no temporary evidence leaf'

        foreach($shape in @('ExistingFile','Directory','ReparseLeaf','UnsafeAncestry','Noncanonical','AlternateStream')){
            $case=New-CcodTask5DefenderAdapterFixture;$caseAdapters=@{};foreach($key in @($case.Adapters.Keys)){if([string]$key-cne'WriteReceipt'){$caseAdapters[[string]$key]=$case.Adapters[$key]}}
            $target=Join-Path $fixture.Root ("invalid-$shape.json")
            $existingText=$null;$cleanupLink=$null
            switch($shape){
                'ExistingFile'{$existingText='do-not-overwrite';[IO.File]::WriteAllText($target,$existingText,[Text.UTF8Encoding]::new($false))}
                'Directory'{[IO.Directory]::CreateDirectory($target)|Out-Null}
                'ReparseLeaf'{$outside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-evidence-leaf-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($outside)|Out-Null;$cleanupLink=$target;New-Item -ItemType Junction -Path $target -Target $outside|Out-Null}
                'UnsafeAncestry'{$unsafeOutside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-evidence-parent-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($unsafeOutside)|Out-Null;$unsafeLink=Join-Path $fixture.Root 'unsafe-evidence-parent';New-Item -ItemType Junction -Path $unsafeLink -Target $unsafeOutside|Out-Null;$target=Join-Path $unsafeLink 'receipt.json';$cleanupLink=$unsafeLink}
                'Noncanonical'{$target=$fixture.Root+'\.\noncanonical-receipt.json'}
                'AlternateStream'{$target=(Join-Path $fixture.Root 'alternate-receipt.json:stream')}
            }
            try{
                Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath $fixture.Installer -ChecksumPath $fixture.Checksum -ManifestPath $fixture.Manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion '2.5.0' -ExpectedGitCommit ('a'*40) -EvidencePath $target -Adapters $caseAdapters|Out-Null} 'CCOD_DEFENDER_EVIDENCE_INVALID'
                Assert-CcodTrue (-not($case.State.Calls-contains'Scan')) "$shape evidence target is rejected before Defender scan"
                if($shape-ceq'ExistingFile'){Assert-CcodEqual $existingText ([IO.File]::ReadAllText($target,[Text.UTF8Encoding]::new($false,$true))) 'existing evidence remains byte-for-byte unchanged'}
            }finally{
                if($null-ne$cleanupLink-and(Test-Path -LiteralPath $cleanupLink)){[IO.Directory]::Delete($cleanupLink)}
                if($shape-ceq'ReparseLeaf'-and$null-ne$outside-and(Test-Path -LiteralPath $outside)){Remove-Item -LiteralPath $outside -Recurse -Force}
                if($shape-ceq'UnsafeAncestry'-and$null-ne$unsafeOutside-and(Test-Path -LiteralPath $unsafeOutside)){Remove-Item -LiteralPath $unsafeOutside -Recurse -Force;$unsafeOutside=$null;$unsafeLink=$null}
            }
        }
    }finally{
        if($null-ne$unsafeLink-and(Test-Path -LiteralPath $unsafeLink)){[IO.Directory]::Delete($unsafeLink)}
        if($null-ne$unsafeOutside-and(Test-Path -LiteralPath $unsafeOutside)){Remove-Item -LiteralPath $unsafeOutside -Recurse -Force}
        if(Test-Path $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force}
    }
}

Invoke-CcodTest 'TrayHost artifact validation requires the exact compiled source name and hash set' {
    Import-Module (Join-Path $repositoryRoot 'build\TrayHostBuild.psm1') -Force
    $artifact = Join-Path ([IO.Path]::GetTempPath()) ('ccod-trayhost-provenance-fixture-' + [guid]::NewGuid().ToString('N'))
    try {
        $commit = 'c' * 40
        Invoke-CcodTrayHostBuild -RepositoryRoot $repositoryRoot -Version '2.5.22' -OutputDirectory $artifact -GitCommit $commit -BuildTimestampUtc '2026-08-28T00:00:00.0000000Z' | Out-Null
        $provenancePath = Join-Path $artifact 'trayhost-build-provenance.json'
        $baselineJson = [IO.File]::ReadAllText($provenancePath,[Text.UTF8Encoding]::new($false))
        $baseline = $baselineJson | ConvertFrom-Json
        $sourceRecords = @($baseline.sourceFiles)
        Assert-CcodTrue (@($sourceRecords.name) -ccontains 'TrayHostChildSession.cs') 'release provenance fixture includes the shared production child session'
        Assert-CcodTrue (@($sourceRecords.name) -ccontains 'WindowsTrayHostRuntime.cs') 'release provenance fixture includes the production Windows runtime adapter'
        Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact -ExpectedGitCommit $commit | Out-Null
        $mutations = @(
            [pscustomobject]@{ Name = 'missing shared child session'; Apply = { param($record) $record.sourceFiles = @($record.sourceFiles | Where-Object { $_.name -cne 'TrayHostChildSession.cs' }) } },
            [pscustomobject]@{ Name = 'duplicate shared child session'; Apply = { param($record) $child = @($record.sourceFiles | Where-Object { $_.name -ceq 'TrayHostChildSession.cs' })[0]; $record.sourceFiles = @($record.sourceFiles | Where-Object { $_.name -cne 'WindowsTrayHostRuntime.cs' }) + @([pscustomobject]@{ name = $child.name; sha256 = $child.sha256 }) } },
            [pscustomobject]@{ Name = 'different source name set'; Apply = { param($record) $child = @($record.sourceFiles | Where-Object { $_.name -ceq 'TrayHostChildSession.cs' })[0]; $child.name = 'TrayHostChildSession-copy.cs' } },
            [pscustomobject]@{ Name = 'Windows runtime source hash mismatch'; Apply = { param($record) $runtime = @($record.sourceFiles | Where-Object { $_.name -ceq 'WindowsTrayHostRuntime.cs' })[0]; $runtime.sha256 = '0' * 64 } }
        )
        foreach ($mutationCase in $mutations) {
            $mutated = $baselineJson | ConvertFrom-Json
            $applyMutation = [scriptblock]$mutationCase.Apply
            & $applyMutation $mutated
            [IO.File]::WriteAllText($provenancePath, ($mutated | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows {
                Test-CcodTrayHostArtifact -RepositoryRoot $repositoryRoot -Version '2.5.22' -ArtifactDirectory $artifact -ExpectedGitCommit $commit | Out-Null
            } 'CCOD_TRAYHOST_SOURCE_TAMPERED'
        }
    } finally {
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest 'CI and release build jobs uniquely gate asset production on the authenticated TrayHost trace' {
    Assert-CcodAuthenticatedTraceWorkflowContract `
        -CiPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') `
        -ReleasePath (Join-Path $repositoryRoot '.github\workflows\release.yml')
}

Invoke-CcodTest 'authenticated trace workflow gate rejects bypass modifiers comments wrong jobs duplicates and post-build placement' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-trace-workflow-fixtures-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $ciPath = Join-Path $root 'ci.yml'
        $releasePath = Join-Path $root 'release.yml'
        $validCi = @'
name: fixture CI
jobs:
  validate:
    steps:
      - name: Run authenticated TrayHost production trace
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@
        $validRelease = @'
name: fixture release
jobs:
  build:
    steps:
      - name: Run authenticated TrayHost production trace
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
      - name: Build assets
        shell: pwsh
        run: |
          $version = '2.5.21'
          ./build/build.ps1 -Version $version
  publish:
    steps:
      - name: Publish fixture
        shell: pwsh
        run: Write-Output publish
'@
        [IO.File]::WriteAllText($ciPath, $validCi, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($releasePath, $validRelease, [Text.UTF8Encoding]::new($false))
        Assert-CcodAuthenticatedTraceWorkflowContract -CiPath $ciPath -ReleasePath $releasePath
        $emptyModifierCi = @'
name: fixture CI
jobs:
  validate:
    steps:
      - name: Run authenticated TrayHost production trace
        if:
        continue-on-error:
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@
        [IO.File]::WriteAllText($ciPath, $emptyModifierCi, [Text.UTF8Encoding]::new($false))
        Assert-CcodAuthenticatedTraceWorkflowContract -CiPath $ciPath -ReleasePath $releasePath
        $invalidFixtures = @(
            [pscustomobject]@{ Name = 'conditional CI trace step'; Ci = @'
name: fixture CI
jobs:
  validate:
    steps:
      - name: Run authenticated TrayHost production trace
        if: ${{ false }}
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@; Release = $validRelease },
            [pscustomobject]@{ Name = 'continue-on-error release trace step'; Ci = $validCi; Release = @'
name: fixture release
jobs:
  build:
    steps:
      - name: Run authenticated TrayHost production trace
        continue-on-error: true
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
      - name: Build assets
        shell: pwsh
        run: ./build/build.ps1 -Version 2.5.21
'@ },
            [pscustomobject]@{ Name = 'comment-only CI decoy'; Ci = @'
name: fixture CI
jobs:
  validate:
    steps:
      # - name: Run authenticated TrayHost production trace
      #   shell: pwsh
      #   run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
      - name: Validate
        shell: pwsh
        run: Write-Output validate
'@; Release = $validRelease },
            [pscustomobject]@{ Name = 'release publish-job decoy'; Ci = $validCi; Release = @'
name: fixture release
jobs:
  build:
    steps:
      - name: Build assets
        shell: pwsh
        run: ./build/build.ps1 -Version 2.5.21
  publish:
    steps:
      - name: Run authenticated TrayHost production trace
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@ },
            [pscustomobject]@{ Name = 'post-build release gate'; Ci = $validCi; Release = @'
name: fixture release
jobs:
  build:
    steps:
      - name: Build assets
        shell: pwsh
        run: ./build/build.ps1 -Version 2.5.21
      - name: Run authenticated TrayHost production trace
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@ },
            [pscustomobject]@{ Name = 'anonymous pre-build release step'; Ci = $validCi; Release = @'
name: fixture release
jobs:
  build:
    steps:
      - run: ./build/build.ps1 -Version 2.5.21
      - name: Run authenticated TrayHost production trace
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@ },
            [pscustomobject]@{ Name = 'duplicate CI gate'; Ci = $validCi + "`n" + @'
      - name: Run authenticated TrayHost production trace
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@; Release = $validRelease },
            [pscustomobject]@{ Name = 'different-name duplicate CI trace invocation'; Ci = $validCi + "`n" + @'
      - name: Trace alias
        shell: pwsh
        run: ./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
'@; Release = $validRelease }
        )
        foreach ($fixture in $invalidFixtures) {
            [IO.File]::WriteAllText($ciPath, [string]$fixture.Ci, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($releasePath, [string]$fixture.Release, [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows {
                Assert-CcodAuthenticatedTraceWorkflowContract -CiPath $ciPath -ReleasePath $releasePath
            } 'CCOD_RELEASE_TRACE_GATE_INVALID'
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest 'package scripts build provenance and workflows retain the release-contract gates' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodTrue ($null -ne $package.scripts.'test:installed-lifecycle') 'package exposes installed-lifecycle deterministic tests'
    Assert-CcodTrue ($null -ne $package.scripts.'test:release-contract') 'package exposes release contract tests'
    $build = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($build -match '\$releaseManifest\s*=\s*Join-Path\s+\$dist\s+\$releaseAssetNames\[4\]') 'build emits the central-contract portable release manifest'
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
    Assert-CcodTrue ($release -match 'New-GitHubReleaseNotes\.ps1') 'release publication uses the behavior-tested English notes extractor'
    Assert-CcodTrue ($release -match 'gh release download') 'existing release assets are downloaded before any publication decision'
    Assert-CcodTrue (-not ($release -match 'gh release upload[^\r\n]*--clobber')) 'release publication never overwrites an existing asset'
    Assert-CcodTrue ($release -match 'Read back published GitHub release assets') 'release publication re-downloads every uploaded asset for hash read-back'
    Assert-CcodTrue ($release -cmatch '(?ms)^permissions:\r?\n\s+contents: read\s*$') 'candidate build starts with read-only repository permission'
    Assert-CcodTrue ($release -cmatch '(?ms)^  publish:\r?\n    needs: build\r?\n    runs-on: windows-latest\r?\n    permissions:\r?\n      contents: write\s*$') 'only the publish job receives release-write permission'
}

$iss = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
Assert-CcodTrue ($buildSource -match 'CodexRemote\.Portable\.exe' -and $buildSource -match 'Copy-CcodBuildPayloadFile' -and $buildSource -match 'New-CcodInstallerPackage') 'build places the portable launcher only in the manifest-listed sealed package'
Assert-CcodTrue ($iss -cnotmatch 'CodexRemote\.Portable\.exe|PortableArtifactDirectory') 'Inno never copies a product launcher outside the sealed package transaction'
Invoke-CcodTest 'release notes extraction emits only the target release English section' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-release-notes-fixture-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $changelogPath = Join-Path $root 'CHANGELOG.md'
        $notesPath = Join-Path $root 'notes.md'
        $fixture = @'
# Fixture release notes

## Unreleased

### English

- UNRELEASED_DECOY

## v2.5.23

### English

- NEWER_DECOY

## v2.5.22

### English

- Target English note.
- Second target English note.

### 简体中文

- CHINESE_DECOY

## v2.5.21

### English

- OLDER_DECOY
'@
        $fixtureCrlf = $fixture.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n")
        [IO.File]::WriteAllText($changelogPath,$fixtureCrlf,[Text.UTF8Encoding]::new($false))
        & (Join-Path $repositoryRoot 'tools\New-GitHubReleaseNotes.ps1') -ChangelogPath $changelogPath -Tag 'v2.5.22' -OutputPath $notesPath | Out-Null
        $actual = [IO.File]::ReadAllText($notesPath,[Text.UTF8Encoding]::new($false))
        Assert-CcodEqual "- Target English note.`n- Second target English note.`n" $actual 'release body contains exactly the current target English notes'
        foreach ($decoy in @('UNRELEASED_DECOY','NEWER_DECOY','CHINESE_DECOY','OLDER_DECOY')) {
            Assert-CcodTrue (-not $actual.Contains($decoy)) "release body excludes $decoy"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest 'release build validates the portable launcher artifact before payload copy' {
    $build = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($build -cmatch '(?s)Invoke-CcodPortableLauncherBuild.*?Test-CcodPortableLauncherArtifact.*?foreach \(\$portableFile in') 'portable build validates the generated artifact before copying it into the payload'
}

Invoke-CcodTask5Test 'docs' 'candidate documentation and build consume the exact non-receipt eleven-asset contract' {
    $expected=Get-CcodTask5ExpectedAssetNames '2.5.22'
    $readme=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'README.md'),[Text.UTF8Encoding]::new($false,$true))
    $readmeZh=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'README.zh-CN.md'),[Text.UTF8Encoding]::new($false,$true))
    Assert-CcodTrue (-not($readme-cmatch'(?i)always published|every tagged release ships|verified and available')) 'English README makes no unconditional publication or verification claim'
    Assert-CcodTrue (-not($readmeZh-cmatch'\u5DF2\u9A8C\u8BC1|\u5747\u53EF\u7528|\u59CB\u7EC8\u53D1\u5E03')) 'Chinese README makes no prior verified or unconditional publication claim'
    $englishRelease=[regex]::Match($readme,'(?ms)^## Releases\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    $chineseRelease=[regex]::Match($readmeZh,'(?ms)^## \u53D1\u5E03\uFF08Releases\uFF09\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    $englishContract=[regex]::Match($englishRelease,'(?ms)<details>\s*<summary>Exact 11-file candidate asset contract</summary>(?<body>.*?)</details>')
    $chineseContract=[regex]::Match($chineseRelease,'(?ms)<details>\s*<summary>\u7CBE\u786E\u7684 11 \u6587\u4EF6\u5019\u9009\u8D44\u4EA7\u5951\u7EA6</summary>(?<body>.*?)</details>')
    Assert-CcodTrue ($englishContract.Success-and$chineseContract.Success) 'both README asset lists are collapsed by default in an exact details block'
    foreach($name in $expected){$literal='`'+$name+'`';Assert-CcodEqual 1 ([regex]::Matches($englishContract.Groups['body'].Value,[regex]::Escape($literal)).Count) "English candidate list names $name exactly once";Assert-CcodEqual 1 ([regex]::Matches($chineseContract.Groups['body'].Value,[regex]::Escape($literal)).Count) "Chinese candidate list names $name exactly once"}
    Assert-CcodTrue ($englishRelease-cmatch'(?i)candidate'-and$chineseRelease-cmatch'\u5019\u9009') 'both release sections scope the eleven files to the v2.5.22 candidate'
    Assert-CcodTrue ($englishRelease-cnotmatch'(?i)defender[^\r\n]*\.json'-and$chineseRelease-cnotmatch'(?i)defender[^\r\n]*\.json') 'Defender receipts are not listed as public assets'
    $build=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'build\build.ps1'),[Text.UTF8Encoding]::new($false,$true))
    Assert-CcodTrue ($build-cmatch'ReleaseAssetContract\.psm1'-and$build-cmatch'Get-CcodExpectedReleaseAssetNames') 'build consumes the central release asset contract'
    foreach($suffix in @('windows-x64.zip','windows-x64.zip.sha256.txt','trayhost-provenance.json','payload-manifest.json','release-manifest.json','setup.exe','setup.exe.sha256.txt','setup-provenance.json','setup-payload-manifest.json','setup-destination-inventory.iss','setup-release-manifest.json')){Assert-CcodTrue ($build-cnotmatch[regex]::Escape('CodexRemote-fix-$Version-'+$suffix)) "build no longer reconstructs $suffix outside the central contract"}
    $changelog=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'CHANGELOG.md'),[Text.UTF8Encoding]::new($false,$true));$section=[regex]::Match($changelog,'(?ms)^## v2\.5\.22\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    Assert-CcodTrue ($section-cmatch'(?i)candidate.*two distinct.*InternetDownload.*Defender receipts'-and$section-cmatch'\u5019\u9009.*InternetDownload.*Defender') 'changelog describes only the enforced candidate evidence contract'
}

Invoke-CcodTest '2.5.22 source metadata and documentation match the release contract' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodEqual '2.5.22' ([string]$package.version) 'package metadata is the 2.5.22 release'
    foreach ($nativeComponent in @('trayhost','portable')) {
        $assemblyInfo = Get-Content -LiteralPath (Join-Path $repositoryRoot ("src\{0}\AssemblyInfo.cs" -f $nativeComponent)) -Raw
        Assert-CcodTrue ($assemblyInfo -cmatch 'AssemblyVersion\("2\.5\.22\.0"\)') "$nativeComponent assembly version is 2.5.22.0"
        Assert-CcodTrue ($assemblyInfo -cmatch 'AssemblyFileVersion\("2\.5\.22\.0"\)') "$nativeComponent file version is 2.5.22.0"
    }
    $trayHostManifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\trayhost\CodexRemote.TrayHost.manifest') -Raw
    Assert-CcodTrue ($trayHostManifest -cmatch '<assemblyIdentity version="2\.5\.22\.0" name="CodexRemote\.fix\.TrayHost"') 'TrayHost embedded manifest identity is 2.5.22.0'
    $portableManifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\portable\CodexRemote.Portable.manifest') -Raw
    Assert-CcodTrue ($portableManifest -cmatch '<assemblyIdentity version="2\.5\.22\.0" name="CodexRemote\.fix\.Portable"') 'portable embedded manifest identity is 2.5.22.0'
    $changelog = Get-Content -LiteralPath (Join-Path $repositoryRoot 'CHANGELOG.md') -Raw
    $releaseSection = [regex]::Match($changelog, '(?ms)^## v2\.5\.22\s*\r?\n(?<body>.*?)(?=^## |\z)')
    Assert-CcodTrue $releaseSection.Success 'v2.5.22 release section exists'
    Assert-CcodTrue ($releaseSection.Groups['body'].Value -match '(?m)^### English\s*$') 'v2.5.22 changelog has concise English release notes'
    $englishSection = [regex]::Match($releaseSection.Groups['body'].Value,'(?ms)^### English\s*\r?\n(?<body>.*?)(?=^### |\z)')
    $englishBullets = @($englishSection.Groups['body'].Value -split '\r?\n' | Where-Object { $_ -cmatch '^- ' })
    Assert-CcodTrue ($englishSection.Success -and $englishBullets.Count -ge 3 -and $englishBullets.Count -le 5) 'v2.5.22 English release notes contain three to five bullets'
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
    $quickStart = [regex]::Match($readme, '(?ms)^## Quick start\s*\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
    Assert-CcodTrue ($readme.Contains('v2.5.22 is the current release candidate') -and $readme.Contains('stable Windows acceptance still requires recorded install, upgrade, reboot, repair, UI, and Defender verification')) 'English README does not claim stable Windows acceptance before real-machine evidence'
    Assert-CcodTrue (-not $readme.Contains("## What's new")) 'English README keeps release details off the home page'
    Assert-CcodTrue ($quickStart.Contains('CodexRemote-fix-2.5.22-setup.exe')) 'English Quick Start names the setup installer'
    Assert-CcodTrue ($quickStart.Contains('CodexRemote-fix-2.5.22-windows-x64.zip')) 'English Quick Start names the portable ZIP'
    Assert-CcodTrue ($quickStart.Contains('CodexRemote-fix.exe')) 'English Quick Start names the portable double-click entrypoint'
    Assert-CcodTrue ($quickStart.Contains('Microsoft Defender')) 'English Quick Start documents the local Defender gate'
    Assert-CcodTrue (-not $readme.Contains('\r\n')) 'English README contains no literal CRLF escape text'
    Assert-CcodTrue ($readme.Contains('The portable distribution publishes its payload manifest as an asset')) 'English README identifies the externally published portable payload manifest'
    Assert-CcodTrue ($readme.Contains('Setup embeds and hash-binds its versioned `installer-payload.manifest.json`')) 'English README identifies the embedded hash-bound setup payload manifest'
    Assert-CcodTrue (-not $readme.Contains('shared payload manifest')) 'English README does not claim setup and portable share one payload manifest'
    $readmeZh = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.zh-CN.md') -Raw -Encoding UTF8
    Assert-CcodTrue ($readmeZh -match 'v2\.5\.22 \u662F\u5F53\u524D\u5019\u9009\u53D1\u5E03\u7248' -and $readmeZh -match '\u7A33\u5B9A\u7248\u9A8C\u6536\u4ECD\u9700\u8BB0\u5F55') 'Chinese README does not claim stable Windows acceptance before real-machine evidence'
    Assert-CcodTrue (-not $readmeZh.Contains("## What's new")) 'Chinese README keeps release details off the home page'
    Assert-CcodTrue ($readmeZh.Contains('CodexRemote-fix-2.5.22-setup.exe')) 'Chinese Quick Start names the setup installer'
    Assert-CcodTrue ($readmeZh.Contains('CodexRemote-fix-2.5.22-windows-x64.zip')) 'Chinese Quick Start names the portable ZIP'
    Assert-CcodTrue ($readmeZh.Contains('CodexRemote-fix.exe')) 'Chinese Quick Start names the portable double-click entrypoint'
    Assert-CcodTrue ($readmeZh.Contains('Microsoft Defender')) 'Chinese Quick Start documents the local Defender gate'
    Assert-CcodTrue ($readmeZh -match '\u4FBF\u643A\u53D1\u884C\u7248\u4F1A\u5916\u53D1\u81EA\u5DF1\u7684 payload manifest') 'Chinese README identifies the externally published portable payload manifest'
    Assert-CcodTrue ($readmeZh -match 'Setup \u5219\u5185\u5D4C\u5E76\u4EE5\u54C8\u5E0C\u7ED1\u5B9A\u7248\u672C\u5316\u7684 `installer-payload\.manifest\.json`') 'Chinese README identifies the embedded hash-bound setup payload manifest'
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

# Production mutation caught: portable validates a payload identity but omits or changes it at the lifecycle child boundary.
Invoke-CcodTest 'portable installer propagates only the exact revalidated sealed identity to its lifecycle child' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-portable-sealed-identity-' + [guid]::NewGuid().ToString('N'))
    $module = $null
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $scriptPath = Join-Path $repositoryRoot 'Install-CodexRemote-fix.ps1'
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
        Assert-CcodEqual 0 @($parseErrors).Count 'portable installer parses before production function extraction'
        $definitions=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})
        $libraryPath=Join-Path $root 'PortableInstallerFunctions.psm1'
        [IO.File]::WriteAllText($libraryPath,(($definitions-join"`r`n`r`n")+"`r`n"),[Text.UTF8Encoding]::new($false))
        $module=Import-Module $libraryPath -Force -PassThru
        $marker=Join-Path $root 'child-identity.txt'
        $child=Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $childSource=@"
param([string]`$InstallRoot,[switch]`$EnableCandidateCompatibleUpdates,[switch]`$DoNotStart,[string]`$SealedPackageSha256)
[IO.File]::WriteAllText('$($marker.Replace("'","''"))',[string]`$SealedPackageSha256,[Text.UTF8Encoding]::new(`$false))
[pscustomobject]@{Outcome='Installed';RuntimeId='runtime-fixture'}
"@
        [IO.File]::WriteAllText($child,$childSource,[Text.UTF8Encoding]::new($false))
        $verified='a'*64
        $receipt=&$module {param($Path,$Root,$Identity)Invoke-CcodPortableLifecycleInstaller -InstallerPath $Path -InstallRoot $Root -CopiedSealedPackageSha256 $Identity -InitialSealedPackageSha256 $Identity -RevalidatedSourceSealedPackageSha256 $Identity} $child $root $verified
        Assert-CcodEqual 'runtime-fixture' ([string]$receipt.RuntimeId) 'portable helper returns the exact child receipt'
        Assert-CcodEqual $verified ([IO.File]::ReadAllText($marker,[Text.UTF8Encoding]::new($false))) 'exact verified identity reaches the lifecycle child'
        Remove-Item -LiteralPath $marker -Force
        Assert-CcodThrows {
            &$module {param($Path,$Root,$Copied,$Expected)Invoke-CcodPortableLifecycleInstaller -InstallerPath $Path -InstallRoot $Root -CopiedSealedPackageSha256 $Copied -InitialSealedPackageSha256 $Expected -RevalidatedSourceSealedPackageSha256 $Expected} $child $root ('b'*64) $verified | Out-Null
        } 'CCOD_PORTABLE_PACKAGE_IDENTITY_INVALID'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $marker)) 'changed identity fails before lifecycle child mutation'
    } finally {
        if($null-ne$module){Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

# Production mutation caught: the real portable entrypoint revalidates source bytes after Defender before copying them.
Invoke-CcodTest 'actual portable entrypoint rejects a post-Defender source mutation before child or lifecycle state' {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-portable-entry-race-'+[guid]::NewGuid().ToString('N'))
    try {
        $payload=Join-Path $root 'payload';$modules=Join-Path $payload 'src\persistence\modules';[IO.Directory]::CreateDirectory($modules)|Out-Null
        $entrypoint=Join-Path $root 'Install-CodexRemote-fix.ps1'
        [IO.File]::Copy((Join-Path $repositoryRoot 'Install-CodexRemote-fix.ps1'),$entrypoint,$false)
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path (Join-Path $repositoryRoot 'Install-CodexRemote-fix.ps1')) (Get-CcodTestFileSha256 -Path $entrypoint) 'fixture invokes an exact copy of the production portable entrypoint'
        [IO.File]::Copy((Join-Path $repositoryRoot 'src\persistence\modules\PortableRelease.psm1'),(Join-Path $modules 'PortableRelease.psm1'),$false)
        [IO.File]::WriteAllText((Join-Path $payload 'package.json'),'{"version":"2.5.22"}',[Text.UTF8Encoding]::new($false))
        $childMarker=Join-Path $root 'child-executed.txt';$lifecycleRoot=Join-Path $root 'lifecycle-state';$child=Join-Path $payload 'Install-CodexControlOtherDevices.ps1'
        $childSource="param([string]`$InstallRoot,[string]`$SealedPackageSha256);[IO.Directory]::CreateDirectory('$($lifecycleRoot.Replace("'","''"))')|Out-Null;[IO.File]::WriteAllText('$($childMarker.Replace("'","''"))',[string]`$SealedPackageSha256,[Text.UTF8Encoding]::new(`$false));[pscustomobject]@{Outcome='Installed';RuntimeId='should-not-run'}"
        [IO.File]::WriteAllText($child,$childSource,[Text.UTF8Encoding]::new($false))
        $records=[Collections.Generic.List[object]]::new()
        foreach($file in @(Get-ChildItem -LiteralPath $payload -File -Force -Recurse)){$relative=$file.FullName.Substring($payload.TrimEnd('\').Length+1).Replace('\','/');$records.Add([pscustomobject][ordered]@{path=$relative;length=[int64]$file.Length;sha256=Get-CcodTestFileSha256 -Path $file.FullName})}
        $comparison=[System.Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)};$records.Sort($comparison)
        $manifest=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version='2.5.22';gitCommit=('a'*40);buildTimestampUtc='2030-02-03T04:05:06.0000000Z';files=@($records)}
        [IO.File]::WriteAllText((Join-Path $root 'payload-manifest.json'),(($manifest|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        $attack=[pscustomobject]@{Ran=$false}
        function Get-MpComputerStatus {[pscustomobject]@{AMServiceEnabled=$true;AntivirusEnabled=$true;RealTimeProtectionEnabled=$true;AMProductVersion='fixture-platform';AMEngineVersion='fixture-engine';AntivirusSignatureVersion='fixture-signature';AntivirusSignatureLastUpdated=[datetime]::UtcNow.AddHours(-1)}}
        function Get-MpThreatDetection {param($ErrorAction)@()}
        function Start-MpScan {param($ScanType,$ScanPath,$ErrorAction)throw 'fixture portable scan failure'}
        $scanFailure=$null
        try{&$entrypoint -DoNotStart|Out-Null}catch{$scanFailure=$_}
        Assert-CcodTrue ($null-ne$scanFailure-and$scanFailure.FullyQualifiedErrorId-like'CCOD_PORTABLE_DEFENDER_SCAN_FAILED*') 'actual entrypoint preserves the portable scan failure code'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $childMarker)-and-not(Test-Path -LiteralPath $lifecycleRoot)) 'portable scan failure creates no child or lifecycle state'
        function Start-MpScan {param($ScanType,$ScanPath,$ErrorAction)$attack.Ran=$true;[IO.File]::WriteAllText($child,'raced-child-source',[Text.UTF8Encoding]::new($false))}
        $failure=$null
        try{&$entrypoint -DoNotStart|Out-Null}catch{$failure=$_}
        Assert-CcodTrue $attack.Ran 'controlled source mutation runs after initial entrypoint validation during its Defender gate'
        Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_PORTABLE_MANIFEST_INVALID*') 'actual entrypoint rejects the raced source at revalidation'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $childMarker)) 'actual entrypoint never executes the marker child'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $lifecycleRoot)) 'actual entrypoint creates no fixture lifecycle state'
    } finally {
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

# Production mutation caught: the real portable entrypoint ignores a child-source race at the final File.Copy barrier.
Invoke-CcodTest 'actual portable entrypoint rejects the final File.Copy barrier race before child or lifecycle state' {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-portable-entry-copy-race-'+[guid]::NewGuid().ToString('N'))
    $redirectBreakpoint=$null;$copyBreakpoint=$null
    try {
        $payload=Join-Path $root 'payload';$modules=Join-Path $payload 'src\persistence\modules';[IO.Directory]::CreateDirectory($modules)|Out-Null
        $entrypoint=Join-Path $root 'Install-CodexRemote-fix.ps1'
        $productionEntrypoint=Join-Path $repositoryRoot 'Install-CodexRemote-fix.ps1'
        [IO.File]::Copy($productionEntrypoint,$entrypoint,$false)
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path $productionEntrypoint) (Get-CcodTestFileSha256 -Path $entrypoint) 'copy-barrier fixture invokes an exact copy of the production portable entrypoint'
        $portableModulePath=Join-Path $modules 'PortableRelease.psm1';$productionPortableModule=Join-Path $repositoryRoot 'src\persistence\modules\PortableRelease.psm1'
        [IO.File]::Copy($productionPortableModule,$portableModulePath,$false)
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path $productionPortableModule) (Get-CcodTestFileSha256 -Path $portableModulePath) 'copy-barrier fixture uses an exact copy of the production portable module'
        [IO.File]::WriteAllText((Join-Path $payload 'package.json'),'{'+'"version":"2.5.22"}',[Text.UTF8Encoding]::new($false))
        $childMarker=Join-Path $root 'child-executed.txt';$fixtureInstallRoot=Join-Path $root 'fixture-install-root';$installerRoot=Join-Path $root 'copied-installer';$child=Join-Path $payload 'Install-CodexControlOtherDevices.ps1'
        $childSource="param([string]`$InstallRoot,[switch]`$EnableCandidateCompatibleUpdates,[switch]`$DoNotStart,[string]`$SealedPackageSha256);[IO.Directory]::CreateDirectory('$($fixtureInstallRoot.Replace("'","''"))')|Out-Null;[IO.File]::WriteAllText('$($childMarker.Replace("'","''"))',[string]`$SealedPackageSha256,[Text.UTF8Encoding]::new(`$false));[pscustomobject]@{Outcome='Installed';RuntimeId='should-not-run'}"
        [IO.File]::WriteAllText($child,$childSource,[Text.UTF8Encoding]::new($false))
        $records=[Collections.Generic.List[object]]::new()
        foreach($file in @(Get-ChildItem -LiteralPath $payload -File -Force -Recurse)){$relative=$file.FullName.Substring($payload.TrimEnd('\').Length+1).Replace('\','/');$records.Add([pscustomobject][ordered]@{path=$relative;length=[int64]$file.Length;sha256=Get-CcodTestFileSha256 -Path $file.FullName})}
        $comparison=[System.Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)};$records.Sort($comparison)
        Assert-CcodEqual 'Install-CodexControlOtherDevices.ps1' ([string]$records[0].path) 'fixture child reaches the first production payload File.Copy barrier'
        $manifest=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version='2.5.22';gitCommit=('a'*40);buildTimestampUtc='2030-02-03T04:05:06.0000000Z';files=@($records)}
        [IO.File]::WriteAllText((Join-Path $root 'payload-manifest.json'),(($manifest|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        function Get-MpComputerStatus {[pscustomobject]@{AMServiceEnabled=$true;AntivirusEnabled=$true;RealTimeProtectionEnabled=$true;AMProductVersion='fixture-platform';AMEngineVersion='fixture-engine';AntivirusSignatureVersion='fixture-signature';AntivirusSignatureLastUpdated=[datetime]::UtcNow.AddHours(-1)}}
        function Get-MpThreatDetection {param($ErrorAction)@()}
        function Start-MpScan {param($ScanType,$ScanPath,$ErrorAction)}
        $barrier=[pscustomobject]@{InstallerRootRedirected=$false;SourceMutated=$false}
        $entryCopyLine=@(Select-String -Path $entrypoint -Pattern '^\s*\$copied = Copy-CcodPortablePayload\b'|ForEach-Object{$_.LineNumber})
        Assert-CcodEqual 1 $entryCopyLine.Count 'production entrypoint copy call is unique'
        $redirectAction={
            $module=@(Get-Module|Where-Object{$_.Path -ceq $portableModulePath})
            if($module.Count-ne 1){throw 'CCOD_TEST_PORTABLE_MODULE_NOT_LOADED'}
            &$module[0] {param($ExpectedRoot)Set-Item -Path Function:Get-CcodPortableReleaseExpectedInstallerRoot -Value { $ExpectedRoot }.GetNewClosure()} $installerRoot
            $barrier.InstallerRootRedirected=$true
        }.GetNewClosure()
        $redirectBreakpoint=Set-PSBreakpoint -Script $entrypoint -Line $entryCopyLine[0] -Action $redirectAction
        $moduleCopyLine=@(Select-String -Path $portableModulePath -Pattern '^\s*\[IO\.File\]::Copy\(\$sourceFile,\$destination,\$false\)'|ForEach-Object{$_.LineNumber})
        Assert-CcodEqual 1 $moduleCopyLine.Count 'production portable payload File.Copy barrier is unique'
        $copyAction={
            [IO.File]::WriteAllText($child,'raced-child-source-at-final-copy-boundary',[Text.UTF8Encoding]::new($false))
            $barrier.SourceMutated=$true
        }.GetNewClosure()
        $copyBreakpoint=Set-PSBreakpoint -Script $portableModulePath -Line $moduleCopyLine[0] -Action $copyAction
        $failure=$null
        try{&$entrypoint -DoNotStart|Out-Null}catch{$failure=$_}
        Assert-CcodTrue $barrier.InstallerRootRedirected 'fixture redirects only the private installer-root dependency before the production copy call'
        Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_PORTABLE_COPY_HASH_MISMATCH*') 'actual entrypoint rejects the source child changed at the production File.Copy barrier'
        Assert-CcodTrue $barrier.SourceMutated 'source child changes only at the production File.Copy barrier'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $childMarker)) 'copy-barrier failure never executes the marker child'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $fixtureInstallRoot)) 'copy-barrier failure creates no fixture lifecycle install root'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $installerRoot)) 'copy-barrier failure publishes no fixture installer root'
    } finally {
        if($null-ne$copyBreakpoint){Remove-PSBreakpoint -Breakpoint $copyBreakpoint -ErrorAction SilentlyContinue}
        if($null-ne$redirectBreakpoint){Remove-PSBreakpoint -Breakpoint $redirectBreakpoint -ErrorAction SilentlyContinue}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

Write-Host 'Release workflow self-tests passed.'
