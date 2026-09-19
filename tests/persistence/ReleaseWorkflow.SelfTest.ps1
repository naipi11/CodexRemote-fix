[CmdletBinding()]
param([string]$FocusedCase)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$defenderPath = Join-Path $repositoryRoot 'tools\Test-ReleaseDefender.ps1'
$releaseDefenderModulePath = Join-Path $repositoryRoot 'tools\ReleaseDefender.psm1'
$assetContractPath = Join-Path $repositoryRoot 'tools\ReleaseAssetContract.psm1'

foreach ($selector in @('CCOD_TASK5_RED_CASE','CCOD_TASK6_RED_CASE')) {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($selector, 'Process'))) {
        throw 'CCOD_RELEASE_TEST_SELECTION_INVALID: inherited selectors are forbidden; use -FocusedCase explicitly.'
    }
}
$script:CcodReleaseFocus = $FocusedCase
$script:CcodReleaseExecuted = 0
$script:CcodReleaseSkipped = 0
if ($PSBoundParameters.ContainsKey('FocusedCase')) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw 'CCOD_RELEASE_TEST_SELECTION_INVALID: test source does not parse.' }
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($command in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Invoke-CcodTask5Test','Invoke-CcodTask6Test') }, $true))) {
        if ($command.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst]) {
            $group = if ($command.GetCommandName() -ceq 'Invoke-CcodTask5Test') { 'Task5' } else { 'Task6' }
            [void]$known.Add($group + ':' + $command.CommandElements[1].Value)
        }
    }
    if ([string]::IsNullOrWhiteSpace($FocusedCase) -or -not $known.Contains($FocusedCase)) {
        throw 'CCOD_RELEASE_TEST_SELECTION_INVALID: unknown explicit case.'
    }
}
$script:CcodReleaseBaseInvokeTest = ${function:Invoke-CcodTest}
function Invoke-CcodReleaseSelectedTest([string]$Id,[string]$Name,[scriptblock]$Action) {
    if ($script:CcodReleaseFocus -and $script:CcodReleaseFocus -cne $Id) { $script:CcodReleaseSkipped++; return }
    $script:CcodReleaseExecuted++
    & $script:CcodReleaseBaseInvokeTest $Name $Action
}
function Invoke-CcodTest([string]$Name,[scriptblock]$Action) { Invoke-CcodReleaseSelectedTest '' $Name $Action }
function Invoke-CcodTask5Test([string]$Id,[string]$Name,[scriptblock]$Action) { Invoke-CcodReleaseSelectedTest ('Task5:' + $Id) $Name $Action }
function Invoke-CcodTask6Test([string]$Id,[string]$Name,[scriptblock]$Action) { Invoke-CcodReleaseSelectedTest ('Task6:' + $Id) $Name $Action }

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
            $currentStep = [pscustomobject]@{ Name = ''; Shell = ''; Run = ''; If = ''; ContinueOnError = ''; Uses = '' }
            $currentJob.Steps.Add($currentStep)
            $key = [string]$Matches.key
            $value = [string]$Matches.value
            if ($key -in @('name', 'shell', 'run', 'if', 'continue-on-error', 'uses')) {
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
                        'uses' { 'Uses' }
                    }
                    $currentStep.$property = ConvertFrom-CcodWorkflowScalar $value
                }
            }
            continue
        }
        if ($null -eq $currentStep) { continue }
        if ($line -cmatch '^        (?<key>name|shell|run|if|continue-on-error|uses):\s*(?<value>.*)$') {
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
                    'uses' { 'Uses' }
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

function New-CcodPortableReleaseFixture {
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-portable-release-workflow-' + [guid]::NewGuid().ToString('N'))
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
    $tray=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version='2.5.6';gitCommit=$commit;buildTimestampUtc=$timestamp;targetFramework='net48';compiler=[ordered]@{name='csc.exe';sha256=('1'*64)};referenceRoot='locked-net48';sourceFiles=@([ordered]@{name='AssemblyInfo.cs';sha256=('2'*64)},[ordered]@{name='WindowsTrayHostRuntime.cs';sha256=('3'*64)});iconSha256=('4'*64);manifestSha256=('5'*64);configSha256=('6'*64);artifactSha256=('7'*64);configArtifactSha256=('8'*64)}
    [IO.File]::WriteAllText($provenance,($tray|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
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
    param([switch]$SetupHashAsArray)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-'+[guid]::NewGuid().ToString('N'));$outside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-outside-'+[guid]::NewGuid().ToString('N'));$work=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-work-'+[guid]::NewGuid().ToString('N'));foreach($directory in @($root,$outside,$work)){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    $version='2.5.22';$commit='c'*40;$timestamp='2030-02-03T04:05:06.0000000Z';$names=Get-CcodTask5ExpectedAssetNames $version
    try{
        $stage=Join-Path $work 'portable-stage';$payload=Join-Path $stage 'payload';[IO.Directory]::CreateDirectory($payload)|Out-Null
        $launcher=Join-Path $stage 'CodexRemote-fix.exe';$launcherConfig=Join-Path $stage 'CodexRemote-fix.exe.config';[IO.File]::WriteAllText((Join-Path $stage 'Install-CodexRemote-fix.ps1'),'Write-Output portable',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllBytes($launcher,[byte[]](1,2,3,4,5));[IO.File]::WriteAllText($launcherConfig,'<configuration/>',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $payload 'hello.txt'),'payload',[Text.UTF8Encoding]::new($false))
        $payloadFile=Join-Path $payload 'hello.txt';$payloadRecord=[ordered]@{path='hello.txt';length=[int64](Get-Item $payloadFile).Length;sha256=Get-CcodTestFileSha256 $payloadFile};$payloadManifest=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;files=@($payloadRecord)}
        [IO.File]::WriteAllText((Join-Path $stage 'payload-manifest.json'),($payloadManifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop;[IO.Compression.ZipFile]::CreateFromDirectory($stage,(Join-Path $root $names[0]),[IO.Compression.CompressionLevel]::Optimal,$false);[IO.File]::WriteAllText((Join-Path $root $names[1]),((Get-CcodTestFileSha256 (Join-Path $root $names[0]))+' *'+$names[0]),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $root $names[3]),($payloadManifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $tray=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;targetFramework='net48';compiler=[ordered]@{name='csc.exe';sha256=('1'*64)};referenceRoot='locked-net48';sourceFiles=@([ordered]@{name='AssemblyInfo.cs';sha256=('2'*64)},[ordered]@{name='WindowsTrayHostRuntime.cs';sha256=('3'*64)});iconSha256=('4'*64);manifestSha256=('5'*64);configSha256=('6'*64);artifactSha256=('7'*64);configArtifactSha256=('8'*64)};Write-CcodTask5Json -Path (Join-Path $root $names[2]) -Value $tray
        $portableAssets=@([ordered]@{name=$names[0];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[0])},[ordered]@{name=$names[1];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[1])},[ordered]@{name=$names[2];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[2])},[ordered]@{name=$names[3];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[3])},[ordered]@{name='CodexRemote-fix.exe';sha256=Get-CcodTestFileSha256 $launcher},[ordered]@{name='CodexRemote-fix.exe.config';sha256=Get-CcodTestFileSha256 $launcherConfig});Write-CcodTask5Json -Path (Join-Path $root $names[4]) -Value ([ordered]@{schemaVersion=2;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;distribution='portable-zip';assets=$portableAssets})
        $packageManifest=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;payloadManifest=[ordered]@{name='installer-payload.manifest.json';length=[int64]123;sha256=('9'*64)};files=@([ordered]@{path='Install-CodexControlOtherDevices.ps1';length=[int64]321;sha256=('a'*64)},[ordered]@{path='package.json';length=[int64]42;sha256=('b'*64)})}
        if ($SetupHashAsArray) { $packageManifest.files[0].sha256 = @($packageManifest.files[0].sha256) }
        Write-CcodTask5Json -Path (Join-Path $root $names[8]) -Value $packageManifest
        $inventory="procedure AddCcodExpectedSetupDirectories(Directories: TStrings);`r`nbegin`r`n  Directories.Add('runtime');`r`nend;`r`n";[IO.File]::WriteAllText((Join-Path $root $names[9]),$inventory,[Text.UTF8Encoding]::new($false));$packageManifestHash=Get-CcodTestFileSha256 (Join-Path $root $names[8]);$packageHash='d'*64;$bootstrapHash='e'*64
        $provenance=[ordered]@{schemaVersion=2;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;installerPackage=[ordered]@{name='installer-package.zip';length=[int64]456;sha256=$packageHash};installerPackageManifest=[ordered]@{name='installer-package.manifest.json';length=[int64](Get-Item (Join-Path $root $names[8])).Length;sha256=$packageManifestHash;fileCount=[int]2;payloadManifestSha256=('9'*64)};activationBootstrap=[ordered]@{name='Activate-CcodRemoteFix.ps1';length=[int64]789;sha256=$bootstrapHash};buildInputs=[ordered]@{innoTemplateSha256=('f'*64);destinationInventorySha256=Get-CcodTestFileSha256 (Join-Path $root $names[9]);compilerSha256=('1'*64);compilerFileVersion='6.7.3'};peContract=[ordered]@{fileVersion="$version.0";packageManifestFirst=$packageManifestHash.Substring(0,32);packageManifestLast=$packageManifestHash.Substring(32,32);bootstrapFirst=$bootstrapHash.Substring(0,32);bootstrapLast=$bootstrapHash.Substring(32,32);companyName=$commit;legalCopyright=$packageHash}};Write-CcodTask5Json -Path (Join-Path $root $names[7]) -Value $provenance
        $iscc=@((Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),(Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))|Where-Object{$_-and[IO.File]::Exists($_)}|Select-Object -First 1;if(-not$iscc){throw 'Inno Setup 6 required for Task5 exact fixture'};$iss=Join-Path $work 'fixture.iss';$out=Join-Path $work 'setup-output';[IO.Directory]::CreateDirectory($out)|Out-Null
        $issText="[Setup]`r`nAppId={{11111111-2222-4333-8444-555555555555}`r`nAppName=CodexRemote-fix`r`nAppVersion=$version`r`nDefaultDirName={tmp}\CcodFixture`r`nCreateAppDir=no`r`nUninstallable=no`r`nPrivilegesRequired=lowest`r`nVersionInfoVersion=$version.0`r`nVersionInfoTextVersion=$version.0`r`nVersionInfoProductName=$($bootstrapHash.Substring(32,32))`r`nVersionInfoProductTextVersion=$($packageManifestHash.Substring(0,32))`r`nVersionInfoDescription=$($packageManifestHash.Substring(32,32))`r`nVersionInfoCompany=$commit`r`nVersionInfoCopyright=$packageHash`r`nVersionInfoOriginalFileName=$($bootstrapHash.Substring(0,32))`r`nOutputBaseFilename=$([IO.Path]::GetFileNameWithoutExtension($names[5]))`r`nCompression=none`r`nDisableProgramGroupPage=yes`r`n";[IO.File]::WriteAllText($iss,$issText,[Text.UTF8Encoding]::new($false));$compile=@(&$iscc "/O$out" $iss 2>&1);if($LASTEXITCODE-ne0){throw "Task5 fixture ISCC failed: $($compile-join' ')"};[IO.File]::Copy((Join-Path $out $names[5]),(Join-Path $root $names[5]),$false)
        [IO.File]::WriteAllText((Join-Path $root $names[6]),((Get-CcodTestFileSha256 (Join-Path $root $names[5]))+' *'+$names[5]),[Text.UTF8Encoding]::new($false));$setupAssets=@([ordered]@{name=$names[5];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[5])},[ordered]@{name=$names[6];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[6])},[ordered]@{name=$names[2];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[2])},[ordered]@{name=$names[7];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[7])},[ordered]@{name=$names[8];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[8])},[ordered]@{name=$names[9];sha256=Get-CcodTestFileSha256 (Join-Path $root $names[9])});Write-CcodTask5Json -Path (Join-Path $root $names[10]) -Value ([ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$version;gitCommit=$commit;buildTimestampUtc=$timestamp;assets=$setupAssets})
        return [pscustomobject]@{Root=$root;OriginalRoot=$root;Outside=$outside;Names=$names;Version=$version;GitCommit=$commit;Timestamp=$timestamp}
    }catch{foreach($path in @($root,$outside)){if(Test-Path $path){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}};throw}finally{if(Test-Path $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}}
}

function Copy-CcodTask5ExactAssetFixture {
    param([Parameter(Mandatory)]$Source)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-copy-'+[guid]::NewGuid().ToString('N'));$outside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-assets-outside-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null;[IO.Directory]::CreateDirectory($outside)|Out-Null;foreach($name in $Source.Names){[IO.File]::Copy((Join-Path $Source.Root $name),(Join-Path $root $name),$false)};[pscustomobject]@{Root=$root;OriginalRoot=$root;Outside=$outside;Names=$Source.Names;Version=$Source.Version;GitCommit=$Source.GitCommit;Timestamp=$Source.Timestamp}
}

function Remove-CcodTask5ExactAssetFixture($Fixture){foreach($path in @($Fixture.Root,$Fixture.OriginalRoot,$Fixture.Outside)){if([string]::IsNullOrWhiteSpace([string]$path)){continue};$full=[IO.Path]::GetFullPath([string]$path);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';if(-not$full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'refusing non-temp asset fixture cleanup'};if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}}}

function New-CcodTask5DefenderStatus {
    [pscustomobject][ordered]@{AMServiceEnabled=$true;AntivirusEnabled=$true;RealTimeProtectionEnabled=$true;AMProductVersion='4.18.26070.1';AMEngineVersion='1.1.26070.1';AntivirusSignatureVersion='1.999.1.0';AntivirusSignatureLastUpdated=[datetime]::Parse('2030-02-03T02:05:06Z').ToUniversalTime()}
}

function New-CcodTask5DefenderAdapterFixture {
    param($Status=(New-CcodTask5DefenderStatus),[datetime]$Started=([datetime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()),$Completed=([datetime]::Parse('2030-02-03T04:05:07Z').ToUniversalTime()),[switch]$ScanThrows,[switch]$Detects,[switch]$WriteThrows)
    $state=[pscustomobject]@{Clock=0;Threat=0;Calls=[Collections.Generic.List[string]]::new()}
    $adapters=@{
        GetDefenderStatus={ $state.Calls.Add('Status');$Status }.GetNewClosure()
        StartCustomScan={param($Path)$state.Calls.Add('Scan');if($ScanThrows){throw 'fixture scan failure'}}.GetNewClosure()
        GetThreatDetections={$state.Calls.Add('Threat');$state.Threat++;if($Detects-and$state.Threat-gt1){@([pscustomobject]@{ThreatID=99;InitialDetectionTime='2030-02-03T04:05:06.0000000Z';Resources=@('redacted')})}else{@()}}.GetNewClosure()
        GetUtcNow={$state.Calls.Add('Clock');$state.Clock++;if($state.Clock-eq1){$Started}else{$Completed}}.GetNewClosure()
    }
    if($WriteThrows){$adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$state.Calls.Add('Write');throw 'fixture evidence write failure'}.GetNewClosure()}
    [pscustomobject]@{Adapters=$adapters;State=$state}
}

function Get-CcodTask5ReleaseDefenderModule {
    $module=@(Get-Module|Where-Object{$_.Path-ceq[IO.Path]::GetFullPath($releaseDefenderModulePath)})|Select-Object -First 1
    if($null-eq$module){$module=Import-Module $releaseDefenderModulePath -Force -PassThru -DisableNameChecking}
    return $module
}

function Invoke-CcodTask5DefenderCore {
    param([string]$CandidatePath,[string]$ChecksumPath,[string]$ManifestPath,[string]$Origin,$WorkflowArtifactIdentity,[string]$ExpectedVersion,[string]$ExpectedGitCommit,[string]$EvidencePath,[hashtable]$Adapters)
    $module=Get-CcodTask5ReleaseDefenderModule
    &$module {param($CandidatePath,$ChecksumPath,$ManifestPath,$Origin,$WorkflowArtifactIdentity,$ExpectedVersion,$ExpectedGitCommit,$EvidencePath,$Adapters)Invoke-CcodReleaseDefenderCheckCore -CandidatePath $CandidatePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -Origin $Origin -WorkflowArtifactIdentity $WorkflowArtifactIdentity -ExpectedVersion $ExpectedVersion -ExpectedGitCommit $ExpectedGitCommit -EvidencePath $EvidencePath -Adapters $Adapters} $CandidatePath $ChecksumPath $ManifestPath $Origin $WorkflowArtifactIdentity $ExpectedVersion $ExpectedGitCommit $EvidencePath $Adapters
}

function Get-CcodTask5DefaultDefenderAdapters {$module=Get-CcodTask5ReleaseDefenderModule;&$module {Get-CcodReleaseDefenderDefaultAdapters}}

function New-CcodTask5WorkflowIdentity([string]$Commit=('a'*40)){
    [pscustomobject][ordered]@{provider='GitHubActions';repository='naipi11/CodexRemote-fix';runId=[uint64]123;runAttempt=[uint64]2;artifactId=[uint64]456;artifactName='CodexRemote-fix portable bundle';artifactDigest=('sha256:'+('9'*64));gitCommit=$Commit}
}

function New-CcodTask5DefenderReceipt {
    param([ValidateSet('Setup','PortableZip')][string]$AssetType='Setup',[string]$Version='2.5.22',[string]$Commit=('c'*40),[ValidateSet('InternetDownload','TrustedWorkflowArtifact')][string]$Origin='InternetDownload')
    $names=Get-CcodTask5ExpectedAssetNames $Version;$setup=$AssetType-ceq'Setup'
    $scanStarted=[datetime]::UtcNow.AddMinutes(-1);$scanCompleted=$scanStarted.AddSeconds(1);$signature=$scanStarted.AddHours(-1)
    [pscustomobject][ordered]@{schemaVersion=2;assetType=$AssetType;assetName=$(if($setup){$names[5]}else{$names[0]});assetSha256=$(if($setup){'5'*64}else{'0'*64});checksumName=$(if($setup){$names[6]}else{$names[1]});checksumSha256=$(if($setup){'6'*64}else{'1'*64});manifestName=$(if($setup){$names[10]}else{$names[4]});manifestSha256=$(if($setup){'a'*64}else{'4'*64});version=$Version;gitCommit=$Commit;origin=$Origin;workflowArtifactIdentity=$(if($Origin-ceq'TrustedWorkflowArtifact'){New-CcodTask5WorkflowIdentity $Commit}else{$null});zoneId=$(if($Origin-ceq'InternetDownload'){3}else{$null});defenderServiceEnabled=$true;antivirusEnabled=$true;realTimeProtectionEnabled=$true;defenderPlatformVersion='4.18.26070.1';defenderEngineVersion='1.1.26070.1';signatureVersion='1.999.1.0';signatureUpdatedAtUtc=$signature.ToString('o');scanStartedAtUtc=$scanStarted.ToString('o');scanCompletedAtUtc=$scanCompleted.ToString('o');detectionCount=0;outcome='Completed';errorCode=$null}
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

function New-CcodTask9ManualEvidenceFixture {
    param([Parameter(Mandatory)][string]$ManifestHash,[string]$Version='2.5.22',[string]$Commit=('c'*40),[string]$ArtifactRoot)
    $operations = @('About','Language','OpenLogs','Repair','SecondDeviceControl')
    $states = @('AboutVisible','LanguageChanged','LogsOpened','RepairCompleted','SecondDeviceControlled')
    $results = @('CCOD_TRAYABOUT_COMPLETED','CCOD_TRAYLANGUAGE_COMPLETED','CCOD_TRAYOPENLOGS_COMPLETED','CCOD_TRAYREPAIR_COMPLETED','CCOD_SECONDDEVICE_COMPLETED')
    $hashes = @(('1' * 64),('2' * 64),('3' * 64),('4' * 64),('5' * 64),('6' * 64),('7' * 64),('8' * 64),('9' * 64),('a' * 64))
    $records = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $operations.Count; $index++) {
        $proof = $null
        if ($index -lt 4) {
            $commands = @('ShowAbout','SetLanguageEnglish','OpenLogs','CheckAndRepair')
            $proof = [pscustomobject][ordered]@{ timestampUtc = '2030-02-03T04:05:07.0000000Z'; command = $commands[$index]; revision = [UInt64]1; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }
        } else {
            $proof = [pscustomobject][ordered]@{ schemaVersion = 1; timestampUtc = '2030-02-03T04:05:07.0000000Z'; kind = 'remote-control-manual-proof'; operation = 'SecondDeviceControl'; deviceRole = 'SecondDevice'; challenge = 'ffffffffffffffffffffffffffffffff'; candidateVersion = $Version; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64); attestation = 'HumanReviewedStructuredAttestation'; connection = 'Connected'; control = 'Completed'; outcome = 'Completed'; code = 'CCOD_REMOTE_ACTION_COMPLETED' }
        }
        $record = [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'manual-evidence'
            phase = if ($index -lt 4) { 'TrayEvidence' } else { 'RemoteEvidence' }
            operation = $operations[$index]
            terminalState = $states[$index]
            result = $results[$index]
            proof = $proof
            reviewState = 'Reviewed'
            version = $Version
            gitCommit = $Commit
            candidateManifestSha256 = $ManifestHash
            screenshotSha256 = $hashes[$index * 2]
            redactedLogSha256 = $hashes[$index * 2 + 1]
        }
        if (-not [string]::IsNullOrWhiteSpace($ArtifactRoot)) {
            $operationDirectory = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) $operations[$index]
            [IO.Directory]::CreateDirectory($operationDirectory) | Out-Null
            $screenshotPath = Join-Path $operationDirectory 'screenshot.bin'
            $redactedLogPath = Join-Path $operationDirectory 'redacted.log'
            [IO.File]::WriteAllText($screenshotPath, "fixture screenshot $Version $Commit $($operations[$index])", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($redactedLogPath, "fixture redacted log $Version $Commit $($operations[$index])", [Text.UTF8Encoding]::new($false))
            $record.screenshotSha256 = Get-CcodTestFileSha256 $screenshotPath
            $record.redactedLogSha256 = Get-CcodTestFileSha256 $redactedLogPath
        }
        $records.Add($record)
    }
    return @($records)
}

function New-CcodTask9AcceptanceRecord {
    param([Parameter(Mandatory)]$AssetFixture,[string]$EvidenceRoot)
    $manifestHash = Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $AssetFixture.Names[4])
    $automated = @()
    $manual = @()
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $state = New-CcodTask9AutomatedAcceptanceState -AssetFixture $AssetFixture -EvidenceRoot $EvidenceRoot
        $automated = @($state.AutomatedReceiptSha256)
        $manual = @($state.ManualEvidence)
    } else {
        $manual = @(New-CcodTask9ManualEvidenceFixture -ManifestHash $manifestHash -Commit ([string]$AssetFixture.GitCommit))
    }
    [ordered]@{
        schemaVersion = 1
        kind = 'official-draft-acceptance'
        version = '2.5.22'
        gitCommit = [string]$AssetFixture.GitCommit
        draft = [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = '123' }
        candidateManifestSha256 = $manifestHash
        phase = 'Complete'
        completedAtUtc = '2030-02-03T04:05:07.0000000Z'
        automatedReceiptSha256 = @($automated)
        manualEvidence = $manual
    }
}

function Get-CcodTask9EvidenceRoot {
    for ($scope = 0; $scope -le 3; $scope++) {
        try { $promotionVariable = Get-Variable -Name promotion -Scope $scope -ValueOnly -ErrorAction Stop } catch { continue }
        if ($null -ne $promotionVariable -and $null -ne $promotionVariable.Root) { return [string]$promotionVariable.Root }
    }
    for ($scope = 0; $scope -le 3; $scope++) {
        try { $evidenceVariable = Get-Variable -Name evidence -Scope $scope -ValueOnly -ErrorAction Stop } catch { continue }
        if ($null -ne $evidenceVariable) { return [string]$evidenceVariable }
    }
    throw 'Task 9 fixture evidence root is unavailable.'
}

function New-CcodTask9AutomatedAcceptanceState {
    param([Parameter(Mandatory)]$AssetFixture,[Parameter(Mandatory)][string]$EvidenceRoot)
    $stateRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) 'official-draft-acceptance'
    $manualRoot = Join-Path $stateRoot 'manual-evidence'
    [IO.Directory]::CreateDirectory($manualRoot) | Out-Null
    $names = [string[]]$AssetFixture.Names
    $assetHashes = @($names | ForEach-Object { [pscustomobject][ordered]@{ name = [string]$_; sha256 = Get-CcodTestFileSha256 (Join-Path $AssetFixture.Root $_) } })
    $candidate = [pscustomobject][ordered]@{
        version = '2.5.22'
        gitCommit = [string]$AssetFixture.GitCommit
        assetHashes = @($assetHashes)
        manifestHashes = [pscustomobject][ordered]@{ portable = [string]$assetHashes[4].sha256; setup = [string]$assetHashes[10].sha256 }
    }
    $draft = [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = '123' }
    $defenderScanStarted=[datetime]::UtcNow.AddMinutes(-1);$defenderScanCompleted=$defenderScanStarted.AddSeconds(1);$defenderSignature=$defenderScanStarted.AddHours(-1)
    $newDefender = {
        param([string]$AssetType)
        $assetIndex = if ($AssetType -ceq 'Setup') { 5 } else { 0 }
        $checksumIndex = if ($AssetType -ceq 'Setup') { 6 } else { 1 }
        $manifestIndex = if ($AssetType -ceq 'Setup') { 10 } else { 4 }
        [pscustomobject][ordered]@{
            schemaVersion = 2; assetType = $AssetType; assetName = $names[$assetIndex]; assetSha256 = $assetHashes[$assetIndex].sha256
            checksumName = $names[$checksumIndex]; checksumSha256 = $assetHashes[$checksumIndex].sha256
            manifestName = $names[$manifestIndex]; manifestSha256 = $assetHashes[$manifestIndex].sha256
            version = '2.5.22'; gitCommit = [string]$AssetFixture.GitCommit; origin = 'InternetDownload'; workflowArtifactIdentity = $null; zoneId = 3
            defenderServiceEnabled = $true; antivirusEnabled = $true; realTimeProtectionEnabled = $true
            defenderPlatformVersion = '4.18.26070.1'; defenderEngineVersion = '1.1.26070.1'; signatureVersion = '1.999.1.0'
            signatureUpdatedAtUtc = $defenderSignature.ToString('o'); scanStartedAtUtc = $defenderScanStarted.ToString('o'); scanCompletedAtUtc = $defenderScanCompleted.ToString('o')
            detectionCount = 0; outcome = 'Completed'; errorCode = $null
        }
    }.GetNewClosure()
    $keyHash = ('b' * 64); $runtimeId = 'runtime-2.5.22'; [UInt64]$generation = 2
    $terminal = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = $runtimeId; runtimeGeneration = $generation; phase = 'Completed' }
    $makeLegacyObservation = {
        param([string]$Version,[string]$ObservedRuntimeId,[UInt64]$ObservedGeneration,[string]$ObservedManifestHash,[string]$ObservedBootId)
        $observedTerminal = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = $ObservedRuntimeId; runtimeGeneration = $ObservedGeneration; phase = 'Completed' }
        return [pscustomobject][ordered]@{
            version = $Version
            bootId = $ObservedBootId
            installRootPresent = $true
            installReady = $true
            appRootPresent = $true
            runtimeRootPresent = $true
            activePointerPresent = $true
            activeRuntimeId = $ObservedRuntimeId
            activeGeneration = $ObservedGeneration
            runtimeManifestSha256 = $ObservedManifestHash
            supervisor = @([pscustomobject][ordered]@{ pid = 200; creationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
            trayHost = @([pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            codex = @([pscustomobject][ordered]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' })
            trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }
            trayAuthenticated = $true
            taskState = 'Ready'
            statusPhase = 'Active'
            statusRuntimeId = $ObservedRuntimeId
            statusCodex = [pscustomobject][ordered]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            transitionStage = 'Idle'
            lifecycleReceipt = $observedTerminal
            aboutVersion = $Version
            deviceKeyPresent = $true
            deviceKeySha256 = $keyHash
            shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
            debugPorts = [int[]]@(9229,9230)
            debugEndpoints = @(
                [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
                [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            )
            protectionReady = $true
        }
    }.GetNewClosure()
    $legacyBeforeObservation = & $makeLegacyObservation '2.5.21' 'runtime-2.5.21' ([UInt64]1) ('2' * 64) 'boot-legacy-before'
    $legacyAfterObservation = & $makeLegacyObservation '2.5.22' $runtimeId $generation ('d' * 64) 'boot-legacy-after'
    $facts = [ordered]@{}
    $defenderReceipts = @(& $newDefender 'Setup')
    $defenderReceipts += @(& $newDefender 'PortableZip')
    $facts.Preflight = [pscustomobject][ordered]@{ defenderReceipts = @($defenderReceipts) }
    $facts.LegacyUpgrade = [pscustomobject][ordered]@{
        previousSetup = [pscustomobject][ordered]@{ version = '2.5.21'; gitCommit = ('a' * 40); assetSha256 = ('1' * 64); manifestSha256 = ('2' * 64) }
        before = $legacyBeforeObservation; after = $legacyAfterObservation
        deviceKeySha256Before = $keyHash; deviceKeySha256After = $keyHash; keyHashPreserved = $true; operationOutcome = 'Completed'
    }
    $facts.Uninstall = [pscustomobject][ordered]@{
        stateRemoved = $true; installRootPresent = $false; appRootPresent = $false; runtimeRootPresent = $false; activePointerPresent = $false; taskState = 'Absent'; supervisorCount = 0; trayHostCount = 0; codexCount = 0
        shortcuts = [pscustomobject][ordered]@{ startMenu = $false; desktop = $false }; debugEndpointsGone = $true
        deviceKeySha256Before = $keyHash; deviceKeySha256After = $keyHash; keyHashPreserved = $true; operationOutcome = 'Completed'
    }
    $facts.FreshInstall = [pscustomobject][ordered]@{
        installRootPresent = $true; installReady = $true; activePointerPresent = $true; activeRuntimeId = $runtimeId; activeGeneration = $generation; runtimeManifestSha256 = ('d' * 64)
        supervisorCount = 1; trayHostCount = 1; codexCount = 1; trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }; trayAuthenticated = $true; taskState = 'Ready'; terminalReceipt = $terminal; protectionReady = $true; deviceKeySha256 = $keyHash; operationOutcome = 'Completed'
    }
    $phaseFiles = [ordered]@{ Preflight = '01-Preflight.json'; LegacyUpgrade = '02-LegacyUpgrade.json'; Uninstall = '03-Uninstall.json'; FreshInstall = '04-FreshInstall.json'; PreReboot = '05-PreReboot.json'; PostReboot = '06-PostReboot.json'; ReadyForManualEvidence = '07-ReadyForManualEvidence.json'; Complete = '08-Complete.json' }
    $writeReceipt = {
        param([string]$Phase,$Value)
        $receipt = [ordered]@{ schemaVersion = 1; phase = $Phase; candidate = $candidate; draft = $draft; facts = $Value }
        [IO.File]::WriteAllText((Join-Path $stateRoot $phaseFiles[$Phase]), (($receipt | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }.GetNewClosure()
    foreach ($phase in @('Preflight','LegacyUpgrade','Uninstall','FreshInstall')) { & $writeReceipt $phase $facts[$phase] }
    $preObservation = & $makeLegacyObservation '2.5.22' $runtimeId $generation ('d' * 64) 'boot-1'
    $facts.PreReboot = [pscustomobject][ordered]@{ rebootRequested = $true; bootIdBefore = 'boot-1'; freshInstallReceiptSha256 = Get-CcodTestFileSha256 (Join-Path $stateRoot $phaseFiles.FreshInstall); activeRuntimeId = $runtimeId; activeGeneration = $generation; runtimeManifestSha256 = $preObservation.runtimeManifestSha256; deviceKeySha256 = $keyHash; operationOutcome = 'Completed'; observation = $preObservation }
    $postObservation = & $makeLegacyObservation '2.5.22' $runtimeId $generation ('d' * 64) 'boot-2'
    $facts.PostReboot = [pscustomobject][ordered]@{
        observation = $postObservation
        installRootPresent = $true; activePointerPresent = $true; bootIdBefore = 'boot-1'; bootIdAfter = 'boot-2'; bootChanged = $true; receiptContinuity = $true; activeRuntimeId = $runtimeId; activeGeneration = $generation; runtimeManifestSha256 = ('d' * 64); transitionStage = 'Idle'
        protectionRecovered = $true; protectionReady = $true; taskState = 'Ready'; supervisorCount = 1; trayHostCount = 1; codexCount = 1; trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }; trayAuthenticated = $true; terminalReceipt = $terminal
        deviceKeySha256 = $keyHash; keyHashPreserved = $true; operationOutcome = 'Completed'
    }
    $facts.ReadyForManualEvidence = [pscustomobject][ordered]@{ automatedPhases = @('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot'); status = 'ReadyForManualEvidence'; manualEvidencePending = $true; complete = $false; manualChallenge = 'ffffffffffffffffffffffffffffffff' }
    & $writeReceipt 'PreReboot' $facts.PreReboot; & $writeReceipt 'PostReboot' $facts.PostReboot; & $writeReceipt 'ReadyForManualEvidence' $facts.ReadyForManualEvidence
    $manual = @(New-CcodTask9ManualEvidenceFixture -ManifestHash $candidate.manifestHashes.portable -Commit $candidate.gitCommit -ArtifactRoot (Join-Path $EvidenceRoot 'official-draft-artifacts'))
    $manualNames = @('TrayEvidence-About.json','TrayEvidence-Language.json','TrayEvidence-OpenLogs.json','TrayEvidence-Repair.json','RemoteEvidence-SecondDeviceControl.json')
    for ($index = 0; $index -lt $manual.Count; $index++) { [IO.File]::WriteAllText((Join-Path $manualRoot $manualNames[$index]), (($manual[$index] | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false)) }
    $facts.Complete = [pscustomobject][ordered]@{ manualEvidence = $manual; status = 'Complete'; complete = $true }
    & $writeReceipt 'Complete' $facts.Complete
    $hashes = [Collections.Generic.List[object]]::new()
    foreach ($phase in @('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','Complete')) { $hashes.Add([pscustomobject][ordered]@{ phase = $phase; sha256 = Get-CcodTestFileSha256 (Join-Path $stateRoot $phaseFiles[$phase]) }) }
    return [pscustomobject][ordered]@{ StateDirectory = $stateRoot; AutomatedReceiptSha256 = @($hashes); ManualEvidence = @($manual) }
}

function Sync-CcodTask5OuterAssetHash {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][ValidateSet('Portable','Setup')][string]$Distribution,[Parameter(Mandatory)][string]$AssetName)
    $manifestName=if($Distribution-ceq'Portable'){$Fixture.Names[4]}else{$Fixture.Names[10]}
    $manifestPath=Join-Path $Fixture.Root $manifestName;$manifest=[IO.File]::ReadAllText($manifestPath,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
    $record=@($manifest.assets|Where-Object{$_.name-ceq$AssetName});if($record.Count-ne1){throw "fixture outer asset missing: $AssetName"}
    $record[0].sha256=Get-CcodTestFileSha256 (Join-Path $Fixture.Root $AssetName)
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
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

Invoke-CcodTask5Test 'review-installed-package-contract' 'installed candidate reader accepts the actual sealed release package manifest' {
    $fixture=$null;$integration=$null
    try {
        $fixture=New-CcodTask5ExactAssetFixture
        $asset=Import-Module $assetContractPath -Force -PassThru
        $contract=Test-CcodExactReleaseAssetSet -AssetDirectory $fixture.Root -Version '2.5.22'
        Assert-CcodTrue $contract.Valid 'the real release validator accepts the fixture before the integration reader'
        $integration=New-Module -ArgumentList (Join-Path $repositoryRoot 'tests/installed/Invoke-InstalledLifecycleIntegration.ps1') -ScriptBlock {param($Path). $Path -Library}
        $path=Join-Path $fixture.Root $fixture.Names[5]
        $result=&$integration {param($Path)Get-CcodInstalledLifecycleCandidate -Path $Path -ExpectedVersion '2.5.22' -Kind Installer -Adapters (Get-CcodInstalledLifecycleDefaultAdapters)} $path
        Assert-CcodEqual (Get-CcodTestFileSha256 $path) $result.Sha256 'integration binds the same installer bytes'
        $package=[IO.File]::ReadAllText((Join-Path $fixture.Root $fixture.Names[8]))|ConvertFrom-Json
        Assert-CcodEqual ($package.files|ConvertTo-Json -Depth 8 -Compress) ($result.PayloadFiles|ConvertTo-Json -Depth 8 -Compress) 'runtime expectations use real package file records'
        [IO.File]::WriteAllText((Join-Path $fixture.Root $fixture.Names[8]),'{}')
        Assert-CcodThrows {&$integration {param($Path)Get-CcodInstalledLifecycleCandidate -Path $Path -ExpectedVersion '2.5.22' -Kind Installer -Adapters (Get-CcodInstalledLifecycleDefaultAdapters)} $path|Out-Null} 'CCOD_INTEGRATION_CANDIDATE_INVALID'
    } finally {
        if($null-ne$integration){Remove-Module $integration.Name -Force -ErrorAction SilentlyContinue}
        if($null-ne$fixture){Remove-CcodTask5ExactAssetFixture $fixture}
    }
}

Invoke-CcodTask5Test 'fix2-setup-file-hash-type' 'Setup file hashes reject singleton arrays with all dependent hashes rebound' {
    $fixture = $null
    $module = Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    try {
        $fixture = New-CcodTask5ExactAssetFixture -SetupHashAsArray
        $package = [IO.File]::ReadAllText((Join-Path $fixture.Root $fixture.Names[8])) | ConvertFrom-Json
        Assert-CcodTrue ($package.files[0].sha256 -is [array]) 'malformed hash remains an array after JSON round-trip'
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath (Join-Path $fixture.Root $fixture.Names[10]) -AssetDirectory $fixture.Root -ExpectedVersion $fixture.Version | Out-Null
        } 'CCOD_RELEASE_MANIFEST_INVALID'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $fixture) { Remove-CcodTask5ExactAssetFixture $fixture }
    }
}

Invoke-CcodTask6Test 'fix2-selector' 'release test selection rejects inherited filters and never reports a partial run as full success' {
    $selfTest = Join-Path $repositoryRoot 'tests\persistence\ReleaseWorkflow.SelfTest.ps1'
    $runChild = {
        param([hashtable]$Environment,[string]$Focus)
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = '-NoLogo -NoProfile -File "' + $selfTest + '"'
        if ($Focus) { $start.Arguments += ' -FocusedCase "' + $Focus + '"' }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($name in @('CCOD_TASK5_RED_CASE','CCOD_TASK6_RED_CASE')) { $start.EnvironmentVariables.Remove($name) }
        foreach ($name in $Environment.Keys) { $start.EnvironmentVariables[$name] = $Environment[$name] }
        $start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
        Assert-CcodTrue ($start.Arguments -notmatch '-ExecutionPolicy') 'selector child does not override normal execution policy'
        Assert-CcodTrue (-not $start.EnvironmentVariables.ContainsKey('PSExecutionPolicyPreference')) 'selector child does not inherit parent process policy'
        $child = [Diagnostics.Process]::new()
        $child.StartInfo = $start
        try {
            [void]$child.Start()
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(60000)) { $child.Kill(); $child.WaitForExit(); throw 'selector child timed out' }
            [pscustomobject]@{ ExitCode = $child.ExitCode; Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
        } finally { $child.Dispose() }
    }.GetNewClosure()
    foreach ($environment in @(
        @{ CCOD_TASK5_RED_CASE = 'unknown-case' },
        @{ CCOD_TASK6_RED_CASE = 'fix1-absolute-tag-anchor' },
        @{ CCOD_TASK5_RED_CASE = ' '; CCOD_TASK6_RED_CASE = 'unknown-case' }
    )) {
        $result = & $runChild $environment ''
        Assert-CcodTrue ($result.ExitCode -ne 0) 'inherited selectors fail rather than silently skipping release gates'
        Assert-CcodTrue ($result.Output.Contains('CCOD_RELEASE_TEST_SELECTION_INVALID')) 'inherited selector failure has a stable marker'
        Assert-CcodTrue (-not $result.Output.Contains('Release workflow self-tests passed')) 'rejected run never reports full success'
    }
    $unknown = & $runChild @{} 'Task6:unknown-case'
    Assert-CcodTrue ($unknown.ExitCode -ne 0 -and $unknown.Output.Contains('CCOD_RELEASE_TEST_SELECTION_INVALID')) 'unknown explicit selection is rejected before running tests'
    $focused = & $runChild @{} 'Task6:fix1-absolute-tag-anchor'
    Assert-CcodEqual 0 $focused.ExitCode 'known explicit focused case executes successfully'
    Assert-CcodTrue ($focused.Output.Contains('CCOD_RELEASE_FOCUSED_TESTS_PASSED')) 'focused mode identifies itself separately'
    Assert-CcodTrue (-not $focused.Output.Contains('Release workflow self-tests passed')) 'focused mode cannot masquerade as a full release suite'
}

Invoke-CcodTask5Test 'fix1-public' 'public Defender surfaces cannot accept adapters or enter library mode' {
    $cli=Get-Command $defenderPath -ErrorAction Stop
    Assert-CcodTrue (-not$cli.Parameters.ContainsKey('Library')) 'Defender CLI exposes no library bypass'
    Assert-CcodTrue (-not$cli.Parameters.ContainsKey('Adapters')) 'Defender CLI exposes no adapter injection parameter'
    foreach($name in @('CandidatePath','ChecksumPath','ManifestPath','Origin','WorkflowArtifactIdentity','ExpectedVersion','ExpectedGitCommit','EvidencePath')){Assert-CcodTrue $cli.Parameters.ContainsKey($name) "Defender CLI retains required public parameter $name"}
    Assert-CcodTrue (Test-Path -LiteralPath $releaseDefenderModulePath -PathType Leaf) 'release Defender module exists'
    $module=Import-Module $releaseDefenderModulePath -Force -PassThru -DisableNameChecking
    try{
        Assert-CcodEqual 'Invoke-CcodReleaseDefenderCheck' ((@($module.ExportedCommands.Keys|Sort-Object))-join',') 'release Defender module exports only the public checker'
        $public=Get-Command Invoke-CcodReleaseDefenderCheck -Module $module.Name -ErrorAction Stop
        Assert-CcodTrue (-not$public.Parameters.ContainsKey('Adapters')) 'public Defender function exposes no adapter injection parameter'
        Assert-CcodThrows {&$defenderPath -Library} 'NamedParameterNotFound'
        Assert-CcodThrows {Invoke-CcodReleaseDefenderCheck -CandidatePath 'x' -ChecksumPath 'x' -ManifestPath 'x' -Origin InternetDownload -ExpectedVersion '2.5.22' -ExpectedGitCommit ('a'*40) -EvidencePath 'x' -Adapters @{}} 'NamedParameterNotFound'
    }finally{Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue}
}

Invoke-CcodTask5Test 'assets' 'release asset contract owns the exact ordered eleven-name set and rejects every mutation' {
    Assert-CcodTrue (Test-Path -LiteralPath $assetContractPath -PathType Leaf) 'central release asset contract module exists'
    $assetModule=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    $template=$null
    try{
        $expected=Get-CcodTask5ExpectedAssetNames '2.5.22';$actual=@(Get-CcodExpectedReleaseAssetNames -Version '2.5.22')
        Assert-CcodEqual ($expected-join'|') ($actual-join'|') 'asset contract returns the literal ordered eleven-name set'
        $template=New-CcodTask5ExactAssetFixture;$validated=Test-CcodExactReleaseAssetSet -AssetDirectory $template.Root -Version $template.Version;Assert-CcodEqual $template.GitCommit ([string]$validated.GitCommit) 'exact set returns the common 40-hex commit';Assert-CcodEqual $template.Timestamp ([string]$validated.BuildTimestampUtc) 'exact set returns the common timestamp';Assert-CcodEqual ($expected-join'|') ((@($validated.Assets.name))-join'|') 'exact set returns all public hashes in contract order'
        foreach($missing in $expected){$fixture=Copy-CcodTask5ExactAssetFixture $template;try{Remove-Item -LiteralPath (Join-Path $fixture.Root $missing) -Force;Assert-CcodThrows {Test-CcodExactReleaseAssetSet -AssetDirectory $fixture.Root -Version $fixture.Version|Out-Null} 'CCOD_RELEASE_ASSET_SET_INVALID'}finally{Remove-CcodTask5ExactAssetFixture $fixture}}
        foreach($mutation in @('Extra','CaseVaried','Directory','Reparse','UnsafeAncestry','NoncanonicalRoot','DuplicateTopProperty','DuplicateNestedProperty','DuplicateEscapedProperty','DuplicateManifest','ManifestOrder','CommitMismatch','TimestampMismatch','SharedProvenanceMismatch')){
            $fixture=Copy-CcodTask5ExactAssetFixture $template
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
    }finally{if($null-ne$template){Remove-CcodTask5ExactAssetFixture $template};if($null-ne$assetModule){Remove-Module -Name $assetModule.Name -Force -ErrorAction SilentlyContinue}}
}

Invoke-CcodTask5Test 'fix1-deep' 'exact asset authority rejects self-consistent nested portable and Setup corruption' {
    $module=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    $template=$null
    try{
        $template=New-CcodTask5ExactAssetFixture
        foreach($mutation in @('PortablePayloadLength','PortablePayloadHash','PortableZipRootLauncher','PortableZipExtra','TrayProvenanceBogusNested','SetupPackagePayloadMismatch','SetupProvenanceBogusNested','SetupProvenanceLength','SetupInventoryDirective')){
            $fixture=Copy-CcodTask5ExactAssetFixture $template
            try{
                switch($mutation){
                    'PortablePayloadLength'{$path=Join-Path $fixture.Root $fixture.Names[3];$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$record.files[0].length=[int64]$record.files[0].length+1;Write-CcodTask5Json -Path $path -Value $record;Sync-CcodTask5OuterAssetHash -Fixture $fixture -Distribution Portable -AssetName $fixture.Names[3]}
                    'PortablePayloadHash'{$path=Join-Path $fixture.Root $fixture.Names[3];$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$record.files[0].sha256='0'*64;Write-CcodTask5Json -Path $path -Value $record;Sync-CcodTask5OuterAssetHash -Fixture $fixture -Distribution Portable -AssetName $fixture.Names[3]}
                    'PortableZipRootLauncher'{$zipPath=Join-Path $fixture.Root $fixture.Names[0];$archive=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Update);try{$archive.GetEntry('CodexRemote-fix.exe').Delete();$entry=$archive.CreateEntry('CodexRemote-fix.exe');$stream=$entry.Open();try{$bytes=[byte[]](9,9,9);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$archive.Dispose()};[IO.File]::WriteAllText((Join-Path $fixture.Root $fixture.Names[1]),((Get-CcodTestFileSha256 $zipPath)+' *'+$fixture.Names[0]),[Text.UTF8Encoding]::new($false));Sync-CcodTask5OuterAssetHash $fixture Portable $fixture.Names[0];Sync-CcodTask5OuterAssetHash $fixture Portable $fixture.Names[1]}
                    'PortableZipExtra'{$zipPath=Join-Path $fixture.Root $fixture.Names[0];$archive=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Update);try{$entry=$archive.CreateEntry('unexpected.txt');$stream=$entry.Open();try{$stream.WriteByte(1)}finally{$stream.Dispose()}}finally{$archive.Dispose()};[IO.File]::WriteAllText((Join-Path $fixture.Root $fixture.Names[1]),((Get-CcodTestFileSha256 $zipPath)+' *'+$fixture.Names[0]),[Text.UTF8Encoding]::new($false));Sync-CcodTask5OuterAssetHash $fixture Portable $fixture.Names[0];Sync-CcodTask5OuterAssetHash $fixture Portable $fixture.Names[1]}
                    'TrayProvenanceBogusNested'{$path=Join-Path $fixture.Root $fixture.Names[2];$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$record.compiler|Add-Member -NotePropertyName bogus -NotePropertyValue 'accepted';Write-CcodTask5Json -Path $path -Value $record;Sync-CcodTask5OuterAssetHash $fixture Portable $fixture.Names[2];Sync-CcodTask5OuterAssetHash $fixture Setup $fixture.Names[2]}
                    'SetupPackagePayloadMismatch'{$path=Join-Path $fixture.Root $fixture.Names[8];$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$record.payloadManifest.sha256='0'*64;Write-CcodTask5Json -Path $path -Value $record;Sync-CcodTask5OuterAssetHash $fixture Setup $fixture.Names[8]}
                    'SetupProvenanceBogusNested'{$path=Join-Path $fixture.Root $fixture.Names[7];$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$record.installerPackageManifest|Add-Member -NotePropertyName bogus -NotePropertyValue 'accepted';Write-CcodTask5Json -Path $path -Value $record;Sync-CcodTask5OuterAssetHash -Fixture $fixture -Distribution Setup -AssetName $fixture.Names[7]}
                    'SetupProvenanceLength'{$path=Join-Path $fixture.Root $fixture.Names[7];$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$record.installerPackageManifest.length=[int64]$record.installerPackageManifest.length+1;Write-CcodTask5Json -Path $path -Value $record;Sync-CcodTask5OuterAssetHash $fixture Setup $fixture.Names[7]}
                    'SetupInventoryDirective'{$path=Join-Path $fixture.Root $fixture.Names[9];[IO.File]::AppendAllText($path,"#include 'foreign.iss'`r`n",[Text.UTF8Encoding]::new($false));Sync-CcodTask5OuterAssetHash -Fixture $fixture -Distribution Setup -AssetName $fixture.Names[9]}
                }
                Assert-CcodThrows {Test-CcodExactReleaseAssetSet -AssetDirectory $fixture.Root -Version $fixture.Version|Out-Null} 'CCOD_RELEASE_ASSET_SET_INVALID'
            }finally{Remove-CcodTask5ExactAssetFixture $fixture}
        }
    }finally{if($null-ne$template){Remove-CcodTask5ExactAssetFixture $template};Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue}
}

Invoke-CcodTask5Test 'fix1-handle-scan' 'Defender scan holds candidate identity against same-byte ABA writes' {
    $fixture=New-CcodTask5ExactAssetFixture
    try{
        $candidate=Join-Path $fixture.Root $fixture.Names[5];$checksum=Join-Path $fixture.Root $fixture.Names[6];$manifest=Join-Path $fixture.Root $fixture.Names[10];Set-Content -LiteralPath $candidate -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`n" -NoNewline
        $probe=[pscustomobject]@{Blocked=$false;Mutated=$false};$case=New-CcodTask5DefenderAdapterFixture
        $case.Adapters.StartCustomScan={param($Path)$case.State.Calls.Add('Scan');$stream=$null;try{$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite);$first=$stream.ReadByte();$stream.Position=0;$stream.WriteByte((($first+1)-band255));$stream.Flush($true);$stream.Position=0;$stream.WriteByte($first);$stream.Flush($true);$probe.Mutated=$true}catch [IO.IOException] {$probe.Blocked=$true}finally{if($null-ne$stream){$stream.Dispose()}}}.GetNewClosure()
        $receipt=Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin InternetDownload -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside 'scan-aba.json') -Adapters $case.Adapters
        Assert-CcodEqual 'Completed' ([string]$receipt.outcome) 'clean fake scan reaches a completed receipt'
        Assert-CcodTrue $probe.Blocked 'candidate write is denied for the entire scan and receipt decision'
        Assert-CcodTrue (-not$probe.Mutated) 'same-byte ABA mutation never obtains a writable handle'
    }finally{Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'fix1-handle-post' 'Defender holds candidate identity through receipt publication and readback' {
    $fixture=New-CcodTask5ExactAssetFixture
    try{
        $candidate=Join-Path $fixture.Root $fixture.Names[5];$checksum=Join-Path $fixture.Root $fixture.Names[6];$manifest=Join-Path $fixture.Root $fixture.Names[10];$probe=[pscustomobject]@{Blocked=$false;Replaced=$false};$backup=$candidate+'.held-original';$case=New-CcodTask5DefenderAdapterFixture;$realPublish=(Get-CcodTask5DefaultDefenderAdapters).PublishReceiptBytes
        $case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$case.State.Calls.Add('Write');try{[IO.File]::Move($candidate,$backup);[IO.File]::Copy($backup,$candidate,$false);$probe.Replaced=$true}catch [IO.IOException] {$probe.Blocked=$true};&$realPublish $Directory $Leaf $Bytes}.GetNewClosure()
        $receipt=Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity (New-CcodTask5WorkflowIdentity $fixture.GitCommit) -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside 'post-revalidate.json') -Adapters $case.Adapters
        Assert-CcodEqual 'Completed' ([string]$receipt.outcome) 'clean fake scan reaches receipt publication'
        Assert-CcodTrue $probe.Blocked 'candidate replacement is denied through durable receipt readback'
        Assert-CcodTrue (-not$probe.Replaced) 'post-revalidation same-byte replacement never changes file identity'
    }finally{
        if(Test-Path -LiteralPath $backup){if(Test-Path -LiteralPath $candidate){Remove-Item -LiteralPath $candidate -Force};Move-Item -LiteralPath $backup -Destination $candidate}
        Remove-CcodTask5ExactAssetFixture $fixture
    }
}

Invoke-CcodTask5Test 'fix1-handle-promotion' 'promotion holds all asset and receipt identities through its final decision' {
    $module=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    $assetFixture=$null;$evidence=$null
    try{
        Assert-CcodTrue ($null-ne(&$module {Get-Command Test-CcodReleasePromotionEvidenceCore -ErrorAction SilentlyContinue})) 'asset module has a private promotion core for controlled replacement tests'
        $source=[IO.File]::ReadAllText($assetContractPath,[Text.UTF8Encoding]::new($false))
        Assert-CcodTrue (([regex]::Matches($source,'foreach\(\$directoryAuthority in @\(\$heldFileDirectories\)\)')).Count -ge 2) 'promotion rechecks every held parent directory before and after the visibility callback'
        $assetFixture=New-CcodTask5ExactAssetFixture;$evidence=New-CcodTask5PromotionFixture $assetFixture;$probe=[pscustomobject]@{AssetBlocked=$false;AssetReplaced=$false;ReceiptBlocked=$false;ReceiptReplaced=$false}
        $assetBackup=(Join-Path $assetFixture.Root $assetFixture.Names[0])+'.original';$receiptPath=Join-Path $evidence.Root $evidence.Names[0];$receiptBackup=$receiptPath+'.original'
        $callback={param($Assets,$Evidence,$Receipts)try{[IO.File]::Move($Assets.Files[0].Path,$assetBackup);[IO.File]::Copy($assetBackup,$Assets.Files[0].Path,$false);$probe.AssetReplaced=$true}catch [IO.IOException] {$probe.AssetBlocked=$true};try{[IO.File]::Move($Receipts[0].Path,$receiptBackup);[IO.File]::Copy($receiptBackup,$Receipts[0].Path,$false);$probe.ReceiptReplaced=$true}catch [IO.IOException] {$probe.ReceiptBlocked=$true}}.GetNewClosure()
        $result=&$module {param($EvidenceRoot,$AssetRoot,$Version,$Commit,$Callback)Test-CcodReleasePromotionEvidenceCore -EvidenceDirectory $EvidenceRoot -AssetDirectory $AssetRoot -Version $Version -ExpectedGitCommit $Commit -BeforeReturn $Callback} $evidence.Root $assetFixture.Root $assetFixture.Version $assetFixture.GitCommit $callback
        Assert-CcodTrue ([bool]$result.Valid) 'promotion core returns a valid held decision'
        Assert-CcodTrue ($probe.AssetBlocked-and$probe.ReceiptBlocked) 'promotion asset and receipt replacements are denied while the decision is live'
        Assert-CcodTrue (-not$probe.AssetReplaced-and-not$probe.ReceiptReplaced) 'promotion callback cannot change any held identity'
    }finally{
        if($null-ne$assetFixture-and(Test-Path -LiteralPath $assetBackup)){if(Test-Path -LiteralPath (Join-Path $assetFixture.Root $assetFixture.Names[0])){Remove-Item -LiteralPath (Join-Path $assetFixture.Root $assetFixture.Names[0]) -Force};Move-Item -LiteralPath $assetBackup -Destination (Join-Path $assetFixture.Root $assetFixture.Names[0])}
        if($null-ne$evidence-and(Test-Path -LiteralPath $receiptBackup)){if(Test-Path -LiteralPath $receiptPath){Remove-Item -LiteralPath $receiptPath -Force};Move-Item -LiteralPath $receiptBackup -Destination $receiptPath}
        if($null-ne$evidence-and(Test-Path $evidence.Root)){Remove-Item -LiteralPath $evidence.Root -Recurse -Force};if($null-ne$assetFixture){Remove-CcodTask5ExactAssetFixture $assetFixture};Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask5Test 'fix1-handle-promotion-post-callback' 'promotion rechecks every held authority after the visibility callback' {
    $module=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    $assetFixture=$null;$evidence=$null
    try{
        $assetFixture=New-CcodTask5ExactAssetFixture;$evidence=New-CcodTask5PromotionFixture $assetFixture
        $callback={param($Assets,$Evidence,$Receipts)
            &$module {param($Authority)Close-CcodExactReleaseAssetAuthority $Authority} $Assets
            &$module {param($Authority)Close-CcodReleaseAuthority $Authority} $Evidence
            foreach($receipt in @($Receipts)){&$module {param($Authority)Close-CcodReleaseAuthority $Authority} $receipt}
        }.GetNewClosure()
        Assert-CcodThrows {
            &$module {param($EvidenceRoot,$AssetRoot,$Version,$Commit,$Callback)Test-CcodReleasePromotionEvidenceCore -EvidenceDirectory $EvidenceRoot -AssetDirectory $AssetRoot -Version $Version -ExpectedGitCommit $Commit -BeforeReturn $Callback} $evidence.Root $assetFixture.Root $assetFixture.Version $assetFixture.GitCommit $callback
        } 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
    }finally{
        if($null-ne$evidence-and(Test-Path $evidence.Root)){Remove-Item -LiteralPath $evidence.Root -Recurse -Force}
        if($null-ne$assetFixture){Remove-CcodTask5ExactAssetFixture $assetFixture};Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

foreach($receiptShape in @('NoOp','Corrupt','WrongTarget','StaleObject','ReplacedReadback','FailedNoOp')){
    Invoke-CcodTask5Test ("fix1-receipt-$receiptShape") ("Defender receipt readback rejects $receiptShape publication") {
        $fixture=New-CcodTask5ExactAssetFixture
        try{
            $candidate=Join-Path $fixture.Root $fixture.Names[5];$checksum=Join-Path $fixture.Root $fixture.Names[6];$manifest=Join-Path $fixture.Root $fixture.Names[10];$evidence=Join-Path $fixture.Outside ("receipt-$receiptShape.json");$case=if($receiptShape-ceq'FailedNoOp'){New-CcodTask5DefenderAdapterFixture -ScanThrows}else{New-CcodTask5DefenderAdapterFixture};$realPublish=(Get-CcodTask5DefaultDefenderAdapters).PublishReceiptBytes
            $controlPath=Join-Path $fixture.Outside 'control.json'
            $control=Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity (New-CcodTask5WorkflowIdentity $fixture.GitCommit) -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath $controlPath -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters
            Assert-CcodEqual 'Completed' $control.outcome 'the same candidate has a passing real publication control'
            $controlHash=Get-CcodTestFileSha256 $controlPath
            switch($receiptShape){
                'NoOp'{$case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$null}}
                'Corrupt'{$case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)&$realPublish $Directory $Leaf ([Text.UTF8Encoding]::new($false).GetBytes('{}'))}.GetNewClosure()}
                'WrongTarget'{$case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)&$realPublish $Directory ($Leaf+'.wrong.json') $Bytes}.GetNewClosure()}
                'StaleObject'{$case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$pin=&$realPublish $Directory $Leaf $Bytes;$pin.Stream.Dispose();$pin.Closed=$true;$pin}.GetNewClosure()}
                'ReplacedReadback'{$case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$pin=&$realPublish $Directory $Leaf $Bytes;$pin.Stream.Dispose();$pin.Closed=$true;$target=Join-Path $Directory.Path $Leaf;$original=$target+'.original';[IO.File]::Move($target,$original);[IO.File]::Copy($original,$target,$false);$pin}.GetNewClosure()}
                'FailedNoOp'{$case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$null}}
            }
            $faultPublish=$case.Adapters.PublishReceiptBytes
            $state=[pscustomobject]@{Calls=0;Authority=$null}
            $case.Adapters.PublishReceiptBytes={param($Directory,$Leaf,$Bytes)$state.Calls++;$value=&$faultPublish $Directory $Leaf $Bytes;$state.Authority=$value;return $value}.GetNewClosure()
            $expected=if($receiptShape-in@('WrongTarget','StaleObject','ReplacedReadback')){'CCOD_DEFENDER_EVIDENCE_CLEANUP_FAILED'}else{'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'}
            Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity (New-CcodTask5WorkflowIdentity $fixture.GitCommit) -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath $evidence -Adapters $case.Adapters|Out-Null} $expected
            Assert-CcodEqual 1 $state.Calls 'the failing publisher is actually invoked once'
            Assert-CcodEqual $controlHash (Get-CcodTestFileSha256 $controlPath) 'failure preserves the unrelated valid receipt'
            if($receiptShape-in@('NoOp','Corrupt','FailedNoOp')){Assert-CcodTrue (-not[IO.File]::Exists($evidence)) 'no-op or rejected owned publication leaves no target'}
            if($receiptShape-ceq'WrongTarget') {
                Assert-CcodTrue (-not[IO.File]::Exists($evidence)) 'wrong-target callback never created the requested receipt'
                Assert-CcodEqual $state.Authority.Sha256 (Get-CcodTestFileSha256 ($evidence+'.wrong.json')) 'cleanup does not guess ownership of the other target'
            }
            if($receiptShape-in@('StaleObject','ReplacedReadback')){Assert-CcodEqual $state.Authority.Sha256 (Get-CcodTestFileSha256 $evidence) 'unverifiable authority is rejected without pathname deletion'}
            if($receiptShape-ceq'ReplacedReadback'){Assert-CcodEqual $state.Authority.Sha256 (Get-CcodTestFileSha256 ($evidence+'.original')) 'detached original is not guessed from its pathname'}
            if($null-ne$state.Authority){Assert-CcodTrue $state.Authority.Closed 'every retained publisher handle is released'}
        }finally{Remove-CcodTask5ExactAssetFixture $fixture}
    }
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
    $defenderModule=Import-Module $releaseDefenderModulePath -Force -PassThru -DisableNameChecking;$assetModule=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    Assert-CcodTrue $assetModule.ExportedCommands.ContainsKey('Test-CcodReleaseAssetManifest') 'release manifest validator is exported for deterministic tests'
    Assert-CcodTrue $defenderModule.ExportedCommands.ContainsKey('Invoke-CcodReleaseDefenderCheck') 'Defender invocation is available'
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
    Import-Module $assetContractPath -Force -DisableNameChecking
    $fixture = New-CcodTask5ExactAssetFixture
    try {
        $manifest=Join-Path $fixture.Root $fixture.Names[10];$installer=Join-Path $fixture.Root $fixture.Names[5];$validated = Test-CcodReleaseAssetManifest -ManifestPath $manifest -AssetDirectory $fixture.Root -ExpectedVersion $fixture.Version
        Assert-CcodEqual $true ([bool]$validated.Valid) 'valid fixture passes the release manifest contract'
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path $installer) ([string]$validated.InstallerSha256) 'validator returns the exact installer hash'
        [IO.File]::WriteAllBytes($installer, [byte[]](1,1,1))
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath $manifest -AssetDirectory $fixture.Root -ExpectedVersion $fixture.Version
        } 'CCOD_RELEASE_ASSET_HASH_MISMATCH'
    } finally {
        Remove-CcodTask5ExactAssetFixture $fixture
    }
}

Invoke-CcodTest 'release timestamp validation reads the raw JSON string representation' {
    $module=Import-Module $assetContractPath -Force -PassThru -DisableNameChecking
    $canonical = '2026-08-24T00:00:00.0000000Z'
    try{Assert-CcodEqual $true (&$module {param($Value)Test-CcodReleaseContractCanonicalUtc $Value} $canonical) 'canonical raw timestamp is retained as exact UTC';Assert-CcodEqual $false (&$module {param($Value)Test-CcodReleaseContractCanonicalUtc $Value} 'not-canonical') 'noncanonical timestamp is rejected'}finally{Remove-Module $module.Name -Force}
}

Invoke-CcodTest 'release manifest rejects a numeric top-level timestamp hidden by a nested canonical timestamp' {
    Import-Module $assetContractPath -Force -DisableNameChecking
    $fixture = New-CcodTask5ExactAssetFixture
    try {
        $canonical = '2026-08-24T00:00:00.0000000Z'
        $trayPath=Join-Path $fixture.Root $fixture.Names[2];$tray=[IO.File]::ReadAllText($trayPath)|ConvertFrom-Json;$tray.buildTimestampUtc=123;$tray|Add-Member -NotePropertyName nested -NotePropertyValue ([pscustomobject]@{buildTimestampUtc=$canonical});Write-CcodTask5Json -Path $trayPath -Value $tray;Sync-CcodTask5OuterAssetHash $fixture Setup $fixture.Names[2]
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath (Join-Path $fixture.Root $fixture.Names[10]) -AssetDirectory $fixture.Root -ExpectedVersion $fixture.Version
        } 'CCOD_RELEASE_MANIFEST_INVALID'
    } finally {
        Remove-CcodTask5ExactAssetFixture $fixture
    }
}

Invoke-CcodTest 'release manifest binds the TrayHost provenance timestamp to its own timestamp' {
    Import-Module $assetContractPath -Force -DisableNameChecking
    $fixture = New-CcodTask5ExactAssetFixture
    try {
        $trayPath=Join-Path $fixture.Root $fixture.Names[2];$tray=[IO.File]::ReadAllText($trayPath)|ConvertFrom-Json;$tray.buildTimestampUtc='2030-02-03T04:05:07.0000000Z';Write-CcodTask5Json -Path $trayPath -Value $tray;Sync-CcodTask5OuterAssetHash $fixture Setup $fixture.Names[2]
        Assert-CcodThrows {
            Test-CcodReleaseAssetManifest -ManifestPath (Join-Path $fixture.Root $fixture.Names[10]) -AssetDirectory $fixture.Root -ExpectedVersion $fixture.Version
        } 'CCOD_RELEASE_MANIFEST_INVALID'
    } finally {
        Remove-CcodTask5ExactAssetFixture $fixture
    }
}

Invoke-CcodTask5Test 'defender' 'Defender gate binds exact origins status clocks manifests and a redacted receipt' {
    $fixture=New-CcodTask5ExactAssetFixture
    try{
        $candidate=Join-Path $fixture.Root $fixture.Names[5];$checksum=Join-Path $fixture.Root $fixture.Names[6];$manifest=Join-Path $fixture.Root $fixture.Names[10];Set-Content -LiteralPath $candidate -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`n" -NoNewline
        $clean=New-CcodTask5DefenderAdapterFixture;$receipt=Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin InternetDownload -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside 'internet.json') -Adapters $clean.Adapters
        $fields='schemaVersion,assetType,assetName,assetSha256,checksumName,checksumSha256,manifestName,manifestSha256,version,gitCommit,origin,workflowArtifactIdentity,zoneId,defenderServiceEnabled,antivirusEnabled,realTimeProtectionEnabled,defenderPlatformVersion,defenderEngineVersion,signatureVersion,signatureUpdatedAtUtc,scanStartedAtUtc,scanCompletedAtUtc,detectionCount,outcome,errorCode'
        Assert-CcodEqual $fields (($receipt.PSObject.Properties.Name)-join',') 'receipt exposes only the exact ordered schema';Assert-CcodEqual 'InternetDownload' $receipt.origin 'official download receipt is origin-bound';Assert-CcodEqual 3 $receipt.zoneId 'official download receipt binds actual ZoneId 3';Assert-CcodEqual $null $receipt.workflowArtifactIdentity 'official download receipt has no workflow identity';Assert-CcodEqual (Get-CcodTestFileSha256 $candidate) $receipt.assetSha256 'receipt binds exact candidate hash';Assert-CcodEqual (Get-CcodTestFileSha256 $manifest) $receipt.manifestSha256 'receipt binds exact matching manifest hash';Assert-CcodTrue (-not(($receipt|ConvertTo-Json -Depth 12 -Compress).Contains($fixture.Root))) 'receipt contains no source path or raw output'
        Remove-Item -LiteralPath $candidate -Stream Zone.Identifier
        foreach($zoneShape in @([pscustomobject]@{Name='absent';Text=$null},[pscustomobject]@{Name='other';Text="[ZoneTransfer]`r`nZoneId=2`r`n"},[pscustomobject]@{Name='duplicate';Text="[ZoneTransfer]`r`nZoneId=3`r`nZoneId=3`r`n"},[pscustomobject]@{Name='mixed';Text="[ZoneTransfer]`r`nZoneId=3`r`nZoneId=2`r`n"})){if($null-ne$zoneShape.Text){Set-Content -LiteralPath $candidate -Stream Zone.Identifier -Value $zoneShape.Text -NoNewline};$case=New-CcodTask5DefenderAdapterFixture;Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin InternetDownload -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside "zone-$($zoneShape.Name).json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_ZONE_REQUIRED';Assert-CcodTrue (-not($case.State.Calls-contains'Scan')) "$($zoneShape.Name) ZoneId metadata blocks scan";if($null-ne$zoneShape.Text){Remove-Item -LiteralPath $candidate -Stream Zone.Identifier}}
        $identity=New-CcodTask5WorkflowIdentity $fixture.GitCommit;$trusted=New-CcodTask5DefenderAdapterFixture;$trustedReceipt=Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside 'trusted.json') -Adapters $trusted.Adapters;Assert-CcodEqual $null $trustedReceipt.zoneId 'trusted workflow receipt never claims Internet Zone';Assert-CcodEqual ($identity|ConvertTo-Json -Compress) ($trustedReceipt.workflowArtifactIdentity|ConvertTo-Json -Compress) 'trusted receipt binds exact workflow artifact identity'
        Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside 'trusted-missing.json') -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters|Out-Null} 'CCOD_DEFENDER_ORIGIN_INVALID'
        Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin InternetDownload -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside 'internet-identity.json') -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters|Out-Null} 'CCOD_DEFENDER_ORIGIN_INVALID'
        foreach($field in @('provider','repository','runId','runAttempt','artifactId','artifactName','artifactDigest','gitCommit')){$bad=(($identity|ConvertTo-Json -Compress)|ConvertFrom-Json);if($field-in@('runId','runAttempt','artifactId')){$bad.$field=0}elseif($field-ceq'artifactDigest'){$bad.$field='sha256:bad'}elseif($field-ceq'gitCommit'){$bad.$field='b'*40}else{$bad.$field='foreign'};Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $bad -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside "trusted-$field.json") -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters|Out-Null} 'CCOD_DEFENDER_ORIGIN_INVALID'}
        foreach($mutation in @('Service','Antivirus','Realtime','Platform','Engine','Signature','SignatureMissing','SignatureStale','SignatureFuture')){$status=New-CcodTask5DefenderStatus;switch($mutation){'Service'{$status.AMServiceEnabled=$false};'Antivirus'{$status.AntivirusEnabled=$false};'Realtime'{$status.RealTimeProtectionEnabled=$false};'Platform'{$status.AMProductVersion=''};'Engine'{$status.AMEngineVersion=''};'Signature'{$status.AntivirusSignatureVersion=''};'SignatureMissing'{$status.AntivirusSignatureLastUpdated=$null};'SignatureStale'{$status.AntivirusSignatureLastUpdated=[datetime]::Parse('2030-01-30T04:05:05Z')};'SignatureFuture'{$status.AntivirusSignatureLastUpdated=[datetime]::Parse('2030-02-03T04:10:07Z')}};$case=New-CcodTask5DefenderAdapterFixture -Status $status;Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside "status-$mutation.json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_STATUS_INVALID';Assert-CcodTrue (-not($case.State.Calls-contains'Scan')) "$mutation blocks scan"}
        foreach($clock in @('Reverse','TooLong','Invalid')){$completed=if($clock-ceq'Reverse'){[datetime]::Parse('2030-02-03T04:05:05Z')}elseif($clock-ceq'TooLong'){[datetime]::Parse('2030-02-03T06:05:07Z')}else{'not-a-clock'};$case=New-CcodTask5DefenderAdapterFixture -Completed $completed;Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside "clock-$clock.json") -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_CLOCK_INVALID'}
        foreach($failure in @('Scan','Detection','Write')){$case=if($failure-ceq'Scan'){New-CcodTask5DefenderAdapterFixture -ScanThrows}elseif($failure-ceq'Detection'){New-CcodTask5DefenderAdapterFixture -Detects}else{New-CcodTask5DefenderAdapterFixture -WriteThrows};$error=if($failure-ceq'Scan'){'CCOD_DEFENDER_SCAN_FAILED'}elseif($failure-ceq'Detection'){'CCOD_DEFENDER_DETECTIONS_FOUND'}else{'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'};Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath (Join-Path $fixture.Outside "failure-$failure.json") -Adapters $case.Adapters|Out-Null} $error}
        $command=Get-Command $defenderPath;Assert-CcodTrue (-not$command.Parameters.ContainsKey('ZoneId')-and-not$command.Parameters.ContainsKey('Adapters')-and-not$command.Parameters.ContainsKey('Library')) 'public tool exposes no Zone synthesis adapter or library bypass parameter'
    }finally{Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'review-defender-existing-threat' 'Defender rejects the same unresolved candidate detection before and after a scan' {
    $fixture=New-CcodTask5ExactAssetFixture
    try {
        $candidate=Join-Path $fixture.Root $fixture.Names[5]
        $invoke=@{CandidatePath=$candidate;ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $control=New-CcodTask5DefenderAdapterFixture
        $clean=Invoke-CcodTask5DefenderCore @invoke -EvidencePath (Join-Path $fixture.Outside 'clean.json') -Adapters $control.Adapters
        Assert-CcodEqual 'Completed' $clean.outcome 'otherwise-valid unchanged candidate passes before introducing the old detection'
        Assert-CcodEqual 2 $control.State.Threat 'passing control observes both sides of the scan'
        [Console]::WriteLine('CCOD_DEFENDER_EXISTING_THREAT_CONTROL_PASSED')
        $record=[pscustomobject]@{ThreatID=[long]99;InitialDetectionTime=([datetime]::Parse('2030-02-02T04:05:06Z').ToUniversalTime());Resources=[string[]]@('file:_'+$candidate);ThreatStatusID=[byte]1;ActionSuccess=$false;ThreatStatusErrorCode=[int]0;AdditionalActionsBitMask=[uint32]0;CurrentThreatExecutionStatusID=[byte]0;LastThreatStatusChangeTime=([datetime]::Parse('2030-02-02T04:05:06Z').ToUniversalTime());RemediationTime=$null}
        $case=New-CcodTask5DefenderAdapterFixture
        $state=$case.State
        $case.Adapters.GetThreatDetections={$state.Calls.Add('Threat');$state.Threat++;return @($record)}.GetNewClosure()
        $path=Join-Path $fixture.Outside 'unresolved.json'
        Assert-CcodThrows {Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters | Out-Null} 'CCOD_DEFENDER_DETECTIONS_FOUND'
        Assert-CcodEqual 2 $state.Threat 'unchanged unresolved detection is observed before and after scanning'
        Assert-CcodEqual 1 @($state.Calls | Where-Object {$_ -ceq 'Scan'}).Count 'the isolated scan adapter actually ran'
        $failed=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        Assert-CcodEqual 'Failed' $failed.outcome 'unresolved candidate never leaves a clean receipt'
        Assert-CcodEqual 1 $failed.detectionCount 'the same detection is counted once rather than omitted or counted twice'
        Assert-CcodTrue (-not([IO.File]::ReadAllText($path).Contains($candidate))) 'receipt does not leak threat resource paths'
    } finally {Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'review-defender-status-drift' 'Defender does not ignore remediation changes under an existing detection key' {
    $fixture=New-CcodTask5ExactAssetFixture
    try {
        $candidate=Join-Path $fixture.Root $fixture.Names[5]
        $invoke=@{CandidatePath=$candidate;ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $initial=[datetime]::Parse('2030-02-02T04:05:06Z').ToUniversalTime()
        $record=[pscustomobject]@{ThreatID=[long]99;InitialDetectionTime=$initial;Resources=[string[]]@('file:_'+$candidate);ThreatStatusID=[byte]2;ActionSuccess=$true;ThreatStatusErrorCode=[int]0;AdditionalActionsBitMask=[uint32]0;CurrentThreatExecutionStatusID=[byte]4;LastThreatStatusChangeTime=$initial.AddMinutes(1);RemediationTime=$initial.AddMinutes(1)}
        foreach($mode in @('Stable','RemediationTime','LastThreatStatusChangeTime','ThreatStatusID','CurrentThreatExecutionStatusID','ThreatStatusErrorCode','AdditionalActionsBitMask','ActionSuccess','MissingStatus','StatusArray','StatusString','BeforeUnresolved','DisappearingUnresolved','Unrelated','SamePrefixOtherFile','ContainerFile','Allowed','UnknownResource')) {
            $case=New-CcodTask5DefenderAdapterFixture;$state=$case.State
            $before=$record.PSObject.Copy()
            $after=$record.PSObject.Copy()
            switch($mode) {
                'RemediationTime'{$after.RemediationTime=$initial.AddMinutes(2)}
                'LastThreatStatusChangeTime'{$after.LastThreatStatusChangeTime=$initial.AddMinutes(2)}
                'ThreatStatusID'{$after.ThreatStatusID=[byte]3}
                'CurrentThreatExecutionStatusID'{$after.CurrentThreatExecutionStatusID=[byte]3}
                'ThreatStatusErrorCode'{$after.ThreatStatusErrorCode=[int]-1}
                'AdditionalActionsBitMask'{$after.AdditionalActionsBitMask=[uint32]8}
                'ActionSuccess'{$after.ActionSuccess=$false}
                'MissingStatus'{$before.PSObject.Properties.Remove('ThreatStatusID');$after.PSObject.Properties.Remove('ThreatStatusID')}
                'StatusArray'{$before.ThreatStatusID=@([byte]2);$after.ThreatStatusID=@([byte]2)}
                'StatusString'{$before.ThreatStatusID='2';$after.ThreatStatusID='2'}
                'BeforeUnresolved'{$before.ThreatStatusID=[byte]1;$before.ActionSuccess=$false}
                'DisappearingUnresolved'{$before.ThreatStatusID=[byte]1;$before.ActionSuccess=$false;$after=$null}
                'Unrelated'{$before.Resources=[string[]]@('file:_' + (Join-Path $fixture.Outside 'other.exe'));$after.Resources=$before.Resources;$before.ActionSuccess=$false;$after.ActionSuccess=$false}
                'SamePrefixOtherFile'{$before.Resources=[string[]]@('file:_' + $candidate + '.other');$after.Resources=$before.Resources;$before.ActionSuccess=$false;$after.ActionSuccess=$false}
                'ContainerFile'{$before.Resources=[string[]]@('containerfile:_' + $candidate + ';file:_inside.exe');$after.Resources=$before.Resources;$before.ActionSuccess=$false;$after.ActionSuccess=$false}
                'Allowed'{$before.ThreatStatusID=[byte]5;$after.ThreatStatusID=[byte]5}
                'UnknownResource'{$before.Resources=[string[]]@('unrecognized-resource');$after.Resources=$before.Resources;$before.ActionSuccess=$false;$after.ActionSuccess=$false}
            }
            $case.Adapters.GetThreatDetections={$state.Calls.Add('Threat');$state.Threat++;if($state.Threat-eq1){$before}else{$after}}.GetNewClosure()
            $path=Join-Path $fixture.Outside ($mode+'.json')
            if($mode-in@('Stable','Unrelated','SamePrefixOtherFile')) {
                $result=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters
                Assert-CcodEqual 'Completed' $result.outcome 'unchanged successfully remediated historical detection is a passing control'
                Assert-CcodEqual 0 $result.detectionCount 'stable clean history is not counted as a new threat'
                [Console]::WriteLine('CCOD_DEFENDER_RESOLVED_HISTORY_CONTROL_PASSED '+$mode)
            } else {
                Assert-CcodThrows {Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_DETECTIONS_FOUND'
                $failed=[IO.File]::ReadAllText($path)|ConvertFrom-Json
                Assert-CcodEqual 'Failed' $failed.outcome 'status changes cannot produce Completed'
                Assert-CcodEqual 1 $failed.detectionCount 'changed existing record is counted once'
            }
            Assert-CcodEqual 2 $state.Threat 'both snapshots are actually observed'
        }
    } finally {Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'review-defender-malformed-observation' 'Defender cannot interpret an unidentified record as empty clean history' {
    $fixture=New-CcodTask5ExactAssetFixture
    try {
        $invoke=@{CandidatePath=(Join-Path $fixture.Root $fixture.Names[5]);ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $control=New-CcodTask5DefenderAdapterFixture
        $clean=Invoke-CcodTask5DefenderCore @invoke -EvidencePath (Join-Path $fixture.Outside 'clean.json') -Adapters $control.Adapters
        Assert-CcodEqual 'Completed' $clean.outcome 'legitimate empty observation passes'
        $case=New-CcodTask5DefenderAdapterFixture;$state=$case.State
        $case.Adapters.GetThreatDetections={$state.Threat++;return @([pscustomobject]@{})}.GetNewClosure()
        $path=Join-Path $fixture.Outside 'invalid.json'
        Assert-CcodThrows {Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_DETECTIONS_INVALID'
        Assert-CcodTrue (-not[IO.File]::Exists($path)) 'unidentified observation cannot create a clean receipt'
        Assert-CcodEqual 1 $state.Threat 'malformed first observation is reached'
        Assert-CcodTrue (-not($state.Calls-contains'Scan')) 'malformed baseline blocks the scan'
    } finally {Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'review2-defender-receipt-rename' 'Defender cannot leave success evidence after an attempted held-receipt rename' {
    $fixture=New-CcodTask5ExactAssetFixture
    try {
        $invoke=@{CandidatePath=(Join-Path $fixture.Root $fixture.Names[5]);ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $controlPath=Join-Path $fixture.Outside 'rename-control.json'
        $control=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $controlPath -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters
        Assert-CcodEqual 'Completed' $control.outcome 'real publisher/readback control passes'
        $controlHash=Get-CcodTestFileSha256 $controlPath
        $path=Join-Path $fixture.Outside 'rename-target.json';$renamed=Join-Path $fixture.Outside 'renamed-success.json';$interference=Join-Path $fixture.Outside 'rename-interference.txt'
        $state=[pscustomobject]@{Attempts=0;Moved=$false;Authority=$null}
        $realPublish=(Get-CcodTask5DefaultDefenderAdapters).PublishReceiptBytes
        $case=New-CcodTask5DefenderAdapterFixture
        $case.Adapters.PublishReceiptBytes={
            param($Directory,$Leaf,$Bytes)
            $pin=&$realPublish $Directory $Leaf $Bytes;$state.Authority=$pin;$state.Attempts++
            try{[IO.File]::Move($pin.Path,$renamed);$state.Moved=$true}catch [IO.IOException]{}
            [IO.File]::WriteAllText($interference,'post-publication membership failure')
            return $pin
        }.GetNewClosure()
        $failure=$null
        try{Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters|Out-Null}catch{$failure=$_.FullyQualifiedErrorId}
        Assert-CcodEqual 1 $state.Attempts 'actual publication occurs before the native rename attempt'
        Assert-CcodTrue ($failure-like'CCOD_DEFENDER_*') 'post-publication failure reaches owned rollback'
        Assert-CcodTrue (-not[IO.File]::Exists($path)-and-not[IO.File]::Exists($renamed)) 'failed invocation leaves no owned Completed receipt under either name'
        Assert-CcodEqual $false $state.Moved 'publisher denies another opener rename while retaining ownership'
        Assert-CcodTrue $state.Authority.Closed 'failure closes the real owned authority'
        Assert-CcodEqual $controlHash (Get-CcodTestFileSha256 $controlPath) 'earlier successful evidence remains untouched'
        Assert-CcodTrue ([IO.File]::Exists($interference)) 'unowned sibling is never deleted by rollback'
        [IO.File]::Delete($interference)
        $retry=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters
        Assert-CcodEqual 'Completed' $retry.outcome 'released authority permits legitimate retry'
    } finally {Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'review-defender-published-rollback' 'Defender removes its published receipt when evidence membership validation fails' {
    $fixture=New-CcodTask5ExactAssetFixture
    try {
        $invoke=@{CandidatePath=(Join-Path $fixture.Root $fixture.Names[5]);ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $control=New-CcodTask5DefenderAdapterFixture
        $controlPath=Join-Path $fixture.Outside 'control.json'
        $clean=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $controlPath -Adapters $control.Adapters
        Assert-CcodEqual 'Completed' $clean.outcome 'unchanged publication and readback pass before injecting failure'
        $controlHash=Get-CcodTestFileSha256 $controlPath
        $case=New-CcodTask5DefenderAdapterFixture
        $publish=(Get-CcodTask5DefaultDefenderAdapters).PublishReceiptBytes
        $state=[pscustomobject]@{Published=$false;Authority=$null;Interference=$null}
        $case.Adapters.PublishReceiptBytes={
            param($Directory,$Leaf,$Bytes)
            $authority=&$publish $Directory $Leaf $Bytes
            $state.Authority=$authority
            $state.Published=[IO.File]::Exists($authority.Path)
            $state.Interference=Join-Path $Directory.Path 'unrelated.txt'
            [IO.File]::WriteAllText($state.Interference,'unrelated-data',[Text.UTF8Encoding]::new($false))
            return $authority
        }.GetNewClosure()
        $path=Join-Path $fixture.Outside 'rejected.json'
        Assert-CcodThrows {Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'
        Assert-CcodTrue $state.Published 'failure occurs after actual native receipt publication'
        Assert-CcodTrue (-not[IO.File]::Exists($path)) 'failed Defender invocation leaves no published success-shaped receipt'
        Assert-CcodTrue $state.Authority.Closed 'owned receipt authority is released after rollback'
        Assert-CcodEqual $controlHash (Get-CcodTestFileSha256 $controlPath) 'rollback preserves the existing valid receipt'
        Assert-CcodEqual 'unrelated-data' ([IO.File]::ReadAllText($state.Interference)) 'rollback does not delete the interfering sibling'
        $retry=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters
        Assert-CcodEqual 'Completed' $retry.outcome 'clean retry proves receipt and directory handles were released'
    } finally {Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'review-defender-readback-final-rollback' 'Defender rolls back readback failures and input drift after successful readback' {
    $fixture=New-CcodTask5ExactAssetFixture
    $module=Import-Module $releaseDefenderModulePath -Force -PassThru -DisableNameChecking
    $original=&$module {${function:Confirm-CcodReleaseDefenderReceiptReadback}}
    try {
        &$module {
            param($Original)
            $script:CcodReviewOriginalReadback=$Original
            function script:Confirm-CcodReleaseDefenderReceiptReadback {
                param($PublishedAuthority,$ReadbackAuthority,[string]$ExpectedPath,[byte[]]$ExpectedBytes,$ExpectedReceipt)
                $script:CcodReviewReadbackState.Readbacks++
                $result=&$script:CcodReviewOriginalReadback @PSBoundParameters
                $script:CcodReviewReadbackState.Confirmed=$true
                if($script:CcodReviewReadbackState.Mode-ceq'FinalInputs') {
                    [IO.File]::WriteAllText($script:CcodReviewReadbackState.Interference,'fixture-input-drift',[Text.UTF8Encoding]::new($false))
                    $script:CcodReviewReadbackState.Injected=$true
                }
                return $result
            }
        } $original
        $invoke=@{CandidatePath=(Join-Path $fixture.Root $fixture.Names[5]);ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $publish=(Get-CcodTask5DefaultDefenderAdapters).PublishReceiptBytes
        foreach($mode in @('Clean','ReadbackBytes','ReadbackLength','FinalInputs')) {
            $state=[pscustomobject]@{Mode=$mode;Readbacks=0;Confirmed=$false;Injected=$false;Authority=$null;Interference=(Join-Path $fixture.Root 'after-confirm.txt')}
            &$module {param($State)$script:CcodReviewReadbackState=$State} $state
            $case=New-CcodTask5DefenderAdapterFixture
            $case.Adapters.PublishReceiptBytes={
                param($Directory,$Leaf,$Bytes)
                $authority=&$publish $Directory $Leaf $Bytes
                $state.Authority=$authority
                if($state.Mode-in@('ReadbackBytes','ReadbackLength')) {
                    $text=[Text.UTF8Encoding]::new($false).GetString($Bytes)
                    $text=if($state.Mode-ceq'ReadbackBytes'){$text.Replace('Completed','CompleteX')}else{$text+' '}
                    $changed=[Text.UTF8Encoding]::new($false).GetBytes($text)
                    $authority.Stream.Position=0;$authority.Stream.Write($changed,0,$changed.Length);$authority.Stream.SetLength($changed.Length);$authority.Stream.Flush($true)
                    $state.Injected=$true
                }
                return $authority
            }.GetNewClosure()
            $path=Join-Path $fixture.Outside ($mode+'.json')
            if($mode-ceq'Clean') {
                $result=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters
                Assert-CcodEqual 'Completed' $result.outcome 'the instrumented actual readback succeeds without interference'
                Assert-CcodTrue $state.Confirmed 'passing control reaches real readback confirmation'
            } else {
                $expected=if($mode-ceq'FinalInputs'){'CCOD_RELEASE_ASSET_HASH_MISMATCH'}else{'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED'}
                Assert-CcodThrows {Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters|Out-Null} $expected
                Assert-CcodTrue $state.Injected "$mode failure is injected at the actual boundary"
                Assert-CcodEqual 1 $state.Readbacks "$mode reaches the real readback helper"
                if($mode-ceq'FinalInputs') {
                    Assert-CcodTrue $state.Confirmed 'final input drift occurs strictly after successful readback'
                    Assert-CcodEqual 'fixture-input-drift' ([IO.File]::ReadAllText($state.Interference)) 'production rollback preserves the unrelated candidate sibling'
                    [IO.File]::Delete($state.Interference)
                }
                Assert-CcodTrue (-not[IO.File]::Exists($path)) "$mode leaves no usable published receipt"
                Assert-CcodTrue $state.Authority.Closed "$mode releases the published file handle"
                $state.Mode='Retry'
                $retry=Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters
                Assert-CcodEqual 'Completed' $retry.outcome "$mode allows a new valid operation after cleanup"
            }
        }
    } finally {
        &$module {param($Original)Set-Item -LiteralPath Function:script:Confirm-CcodReleaseDefenderReceiptReadback -Value $Original;Remove-Variable -Name CcodReviewOriginalReadback,CcodReviewReadbackState -Scope Script -ErrorAction SilentlyContinue} $original
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        Remove-CcodTask5ExactAssetFixture $fixture
    }
}

Invoke-CcodTask5Test 'review-defender-rollback-lost-authority' 'Defender cleanup fails closed without deleting a pathname replacement after authority loss' {
    $fixture=New-CcodTask5ExactAssetFixture
    try {
        $invoke=@{CandidatePath=(Join-Path $fixture.Root $fixture.Names[5]);ChecksumPath=(Join-Path $fixture.Root $fixture.Names[6]);ManifestPath=(Join-Path $fixture.Root $fixture.Names[10]);Origin='TrustedWorkflowArtifact';WorkflowArtifactIdentity=(New-CcodTask5WorkflowIdentity $fixture.GitCommit);ExpectedVersion=$fixture.Version;ExpectedGitCommit=$fixture.GitCommit}
        $clean=Invoke-CcodTask5DefenderCore @invoke -EvidencePath (Join-Path $fixture.Outside 'control.json') -Adapters (New-CcodTask5DefenderAdapterFixture).Adapters
        Assert-CcodEqual 'Completed' $clean.outcome 'valid publication succeeds with retained authority'
        $publish=(Get-CcodTask5DefaultDefenderAdapters).PublishReceiptBytes
        $state=[pscustomobject]@{Replaced=$false;OwnedPath=$null;Authority=$null}
        $case=New-CcodTask5DefenderAdapterFixture
        $case.Adapters.PublishReceiptBytes={
            param($Directory,$Leaf,$Bytes)
            $authority=&$publish $Directory $Leaf $Bytes
            $state.Authority=$authority
            $authority.Stream.Dispose();$authority.Closed=$true
            $state.OwnedPath=Join-Path $Directory.Path 'detached.json'
            [IO.File]::Move($authority.Path,$state.OwnedPath)
            [IO.File]::WriteAllText($authority.Path,'unrelated-replacement',[Text.UTF8Encoding]::new($false))
            $state.Replaced=$true
            return $authority
        }.GetNewClosure()
        $path=Join-Path $fixture.Outside 'replaced.json'
        Assert-CcodThrows {Invoke-CcodTask5DefenderCore @invoke -EvidencePath $path -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_EVIDENCE_CLEANUP_FAILED'
        Assert-CcodTrue $state.Replaced 'fixture actually replaces the published pathname after closing its authority'
        Assert-CcodEqual 'unrelated-replacement' ([IO.File]::ReadAllText($path)) 'failure never falls back to deleting the replacement by pathname'
        Assert-CcodTrue ([IO.File]::Exists($state.OwnedPath)) 'lost ownership is reported rather than guessed from another path'
        Assert-CcodTrue $state.Authority.Closed 'the lost authority remains closed'
    } finally {Remove-CcodTask5ExactAssetFixture $fixture}
}

Invoke-CcodTask5Test 'evidence' 'Defender default evidence writer is create-only and rejects unsafe targets before scan' {
    $fixture=New-CcodTask5ExactAssetFixture
    $unsafeOutside=$null;$unsafeLink=$null
    try{
        $candidate=Join-Path $fixture.Root $fixture.Names[5];$checksum=Join-Path $fixture.Root $fixture.Names[6];$manifest=Join-Path $fixture.Root $fixture.Names[10];$identity=New-CcodTask5WorkflowIdentity $fixture.GitCommit
        $clean=New-CcodTask5DefenderAdapterFixture;$evidence=Join-Path $fixture.Outside 'create-only-receipt.json'
        $receipt=Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath $evidence -Adapters $clean.Adapters
        Assert-CcodTrue (Test-Path -LiteralPath $evidence -PathType Leaf) 'default writer creates the requested regular evidence leaf'
        $persisted=[IO.File]::ReadAllText($evidence,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
        Assert-CcodEqual ($receipt|ConvertTo-Json -Depth 12 -Compress) ($persisted|ConvertTo-Json -Depth 12 -Compress) 'default writer persists only the returned canonical receipt'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $fixture.Outside -Force|Where-Object{$_.Name-like'.ccod-defender-receipt-*'}).Count 'default writer leaves no temporary evidence leaf'

        foreach($shape in @('ExistingFile','Directory','ReparseLeaf','UnsafeAncestry','Noncanonical','AlternateStream')){
            $case=New-CcodTask5DefenderAdapterFixture;$target=Join-Path $fixture.Outside ("invalid-$shape.json")
            $existingText=$null;$cleanupLink=$null
            switch($shape){
                'ExistingFile'{$existingText='do-not-overwrite';[IO.File]::WriteAllText($target,$existingText,[Text.UTF8Encoding]::new($false))}
                'Directory'{[IO.Directory]::CreateDirectory($target)|Out-Null}
                'ReparseLeaf'{$outside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-evidence-leaf-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($outside)|Out-Null;$cleanupLink=$target;New-Item -ItemType Junction -Path $target -Target $outside|Out-Null}
                'UnsafeAncestry'{$unsafeOutside=Join-Path ([IO.Path]::GetTempPath()) ('ccod-task5-evidence-parent-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($unsafeOutside)|Out-Null;$unsafeLink=Join-Path $fixture.Outside 'unsafe-evidence-parent';New-Item -ItemType Junction -Path $unsafeLink -Target $unsafeOutside|Out-Null;$target=Join-Path $unsafeLink 'receipt.json';$cleanupLink=$unsafeLink}
                'Noncanonical'{$target=$fixture.Outside+'\.\noncanonical-receipt.json'}
                'AlternateStream'{$target=(Join-Path $fixture.Outside 'alternate-receipt.json:stream')}
            }
            try{
                Assert-CcodThrows {Invoke-CcodTask5DefenderCore -CandidatePath $candidate -ChecksumPath $checksum -ManifestPath $manifest -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $identity -ExpectedVersion $fixture.Version -ExpectedGitCommit $fixture.GitCommit -EvidencePath $target -Adapters $case.Adapters|Out-Null} 'CCOD_DEFENDER_EVIDENCE_INVALID'
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
        Remove-CcodTask5ExactAssetFixture $fixture
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
    Assert-CcodTrue ((Get-Content -LiteralPath (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') -Raw) -match 'gh release download') 'draft promoter reads back staged assets through gh adapters'
    Assert-CcodTrue (-not ($release -match 'gh release upload[^\r\n]*--clobber')) 'release publication never overwrites an existing asset'
    Assert-CcodTrue ($release -match 'Invoke-CcodGitHubDraftRelease -Mode Verify') 'release publication re-downloads every uploaded asset for hash read-back'
    Assert-CcodTrue ($release -cmatch '(?ms)^permissions:\r?\n\s+contents: read\s*$') 'candidate build starts with read-only repository permission'
    Assert-CcodTrue ($release -cmatch '(?ms)^  stage:\r?\n    needs: build\r?\n    runs-on: windows-latest\r?\n    permissions:\r?\n      contents: write\s*$') 'only the stage job receives release-write permission'
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
    Import-Module $assetContractPath -Force -DisableNameChecking
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

function Import-CcodTask6ToolModule {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)
    $existing = Get-Module -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) { Remove-Module -Name $Name -Force }
    $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path), [Text.UTF8Encoding]::new($false))
    $created = New-Module -Name $Name -ScriptBlock ([scriptblock]::Create($text))
    Import-Module $created -Force -DisableNameChecking | Out-Null
    $loaded = Get-Module -Name $Name
    if ($null -eq $loaded) { throw "CCOD_TASK6_TOOL_MODULE_MISSING $Name" }
    & $loaded { param($Root) $script:CcodGitHubDraftModuleRoot = [IO.Path]::GetFullPath($Root) } (Split-Path (Get-Item -LiteralPath $Path).FullName -Parent)
    return $loaded
}

function Assert-CcodDraftReleaseWorkflowContract {
    param(
        [Parameter(Mandatory)][string]$CiPath,
        [Parameter(Mandatory)][string]$ReleasePath
    )
    $errorId = 'CCOD_RELEASE_WORKFLOW_INVALID'
    $pins = [ordered]@{
        'actions/checkout' = '11d5960a326750d5838078e36cf38b85af677262'
        'actions/setup-node' = '49933ea5288caeca8642d1e84afbd3f7d6820020'
        'actions/upload-artifact' = 'ea165f8d65b6e75b540449e92b4886f43607fa02'
        'actions/download-artifact' = 'd3f86a106a0bac45b974a628896c90dbdf5c8093'
    }
    foreach ($target in @($CiPath, $ReleasePath)) {
        $raw = [IO.File]::ReadAllText($target, [Text.UTF8Encoding]::new($false))
        if ($raw -cmatch 'uses:\s*actions/[A-Za-z0-9_.-]+@v\d') { throw $errorId }
        if ($raw -cmatch '(?m)^\s*continue-on-error:') { throw $errorId }
        foreach ($use in @([regex]::Matches($raw, '(?m)^\s+uses:\s*(?<ref>\S+)\s*$'))) {
            if ($use.Groups['ref'].Value -cnotmatch '^actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}$') { throw $errorId }
            $action = ($use.Groups['ref'].Value -split '@')[0]
            $sha = ($use.Groups['ref'].Value -split '@')[1]
            if (-not $pins.Contains($action) -or $pins[$action] -cne $sha) { throw $errorId }
        }
    }
    $ci = [IO.File]::ReadAllText($CiPath, [Text.UTF8Encoding]::new($false))
    $release = [IO.File]::ReadAllText($ReleasePath, [Text.UTF8Encoding]::new($false))
    foreach ($action in @('actions/checkout','actions/setup-node')) {
        if (-not $ci.Contains($action + '@' + $pins[$action])) { throw $errorId }
    }
    foreach ($action in @($pins.Keys)) {
        if (-not $release.Contains($action + '@' + $pins[$action])) { throw $errorId }
    }
    if ($release -cmatch 'build/dist/\*' -or $release -cmatch '\.Extension\s+-in' -or $release -cmatch 'Test-ReleaseDefender\.ps1[^\r\n]*-Library') { throw $errorId }
    if ($release -cnotmatch 'ReleaseAssetContract\.psm1' -or $release -cnotmatch 'Get-CcodExpectedReleaseAssetNames' -or $release -cnotmatch 'Test-CcodCleanReleaseRunner' -or $release -cnotmatch 'Invoke-CcodGitHubDraftRelease') { throw $errorId }
    if ($release -cmatch '(?m)gh release create\b(?![^\r\n]*--draft)') { throw $errorId }
    if ($release -cnotmatch '(?m)^concurrency:' -or $release -cnotmatch 'cancel-in-progress:\s*false') { throw $errorId }
    $workflow = Get-CcodWorkflowStructure -Path $ReleasePath
    $jobNames = @($workflow.Jobs | ForEach-Object { $_.Name })
    $preflightIndex = [array]::IndexOf($jobNames, 'preflight')
    $buildIndex = [array]::IndexOf($jobNames, 'build')
    if ($preflightIndex -lt 0 -or $buildIndex -lt 0 -or $preflightIndex -ge $buildIndex) { throw $errorId }
    $cleanSteps = @($workflow.Jobs[$preflightIndex].Steps | Where-Object { [string]$_.Run -cmatch 'Test-CcodCleanReleaseRunner' })
    if ($cleanSteps.Count -lt 1) { throw $errorId }
    $normalized = $release.Replace("`r`n", "`n")
    $stageBlocks = @([regex]::Matches($normalized, '(?ms)^  stage:\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\z)'))
    if ($stageBlocks.Count -ne 1) { throw $errorId }
    $stageBody = $stageBlocks[0].Groups['body'].Value
    if ($normalized -cnotmatch '(?m)^permissions:\n  contents: read$' -or
        @([regex]::Matches($normalized, '(?m)^[ ]*contents: write[ ]*$')).Count -ne 1 -or
        $stageBody -cnotmatch '(?m)^    permissions:\n      contents: write$' -or
        $stageBody -cnotmatch '(?m)^    needs: build$' -or
        $stageBody -cnotmatch '(?m)^          ref: \$\{\{ needs\.build\.outputs\.commit \}\}$') { throw $errorId }
    foreach ($transfer in @(
        [pscustomobject]@{ Job = 'preflight'; Step = 'Upload immutable clean preflight evidence' },
        [pscustomobject]@{ Job = 'stage'; Step = 'Download immutable clean preflight evidence' },
        [pscustomobject]@{ Job = 'stage'; Step = 'Materialize transferred clean preflight evidence' }
    )) {
        $owner = @($workflow.Jobs | Where-Object { $_.Name -ceq $transfer.Job })
        if ($owner.Count -ne 1) { throw $errorId }
        $steps = @($owner[0].Steps | Where-Object { $_.Name -ceq $transfer.Step })
        if ($steps.Count -ne 1 -or -not [string]::IsNullOrEmpty([string]$steps[0].If)) { throw $errorId }
    }
    foreach ($job in @($workflow.Jobs)) {
        foreach ($step in @($job.Steps)) {
            if (-not [string]::IsNullOrEmpty([string]$step.ContinueOnError)) { throw $errorId }
            if ($job.Name -cne 'build' -and (Test-CcodWorkflowStepInvokesBuild $step)) { throw $errorId }
            if (([string]$step.Run -cmatch 'Test-CcodCleanReleaseRunner|Invoke-CcodGitHubDraftRelease|test:release-contract|build\.ps1') -and -not [string]::IsNullOrEmpty([string]$step.If)) { throw $errorId }
        }
    }
}

function New-CcodTask6CleanAdapterFixture {
    param(
        [string]$Version = '2.5.22',
        [string]$Commit = ('c' * 40),
        [string]$Porcelain = '',
        [switch]$Installed,
        [switch]$MutexOccupied,
        [switch]$TaskPresent,
        [switch]$SupervisorPresent,
        [switch]$TrayHostPresent
    )
    $state = [pscustomobject]@{ Calls = [Collections.Generic.List[string]]::new(); Preflight = $null; Cleanup = [Collections.Generic.List[string]]::new() }
    $adapters = @{
        GetPackageVersion = { param($Root) $state.Calls.Add('GetPackageVersion'); $Version }.GetNewClosure()
        GetGitPorcelain = { param($Root) $state.Calls.Add('GetGitPorcelain'); $Porcelain }.GetNewClosure()
        GetGitCommit = { param($Root) $state.Calls.Add('GetGitCommit'); $Commit }.GetNewClosure()
        GetProductState = { param($Root) $state.Calls.Add('GetProductState'); [pscustomobject]@{ InstallRootPresent = [bool]$Installed; ScheduledTaskPresent = [bool]$TaskPresent; SupervisorPresent = [bool]$SupervisorPresent; TrayHostPresent = [bool]$TrayHostPresent } }.GetNewClosure()
        ProbeMutex = { param($Kind) $state.Calls.Add('ProbeMutex:' + $Kind); [bool]$MutexOccupied }.GetNewClosure()
        WritePreflightEvidence = { param($Path, $Record) $state.Calls.Add('WritePreflightEvidence'); $state.Preflight = [pscustomobject]@{ Path = $Path; Record = $Record }; $Path }.GetNewClosure()
        CleanupProduct = { param($Root) $state.Cleanup.Add('CleanupProduct'); throw 'cleanup forbidden' }.GetNewClosure()
    }
    [pscustomobject]@{ Adapters = $adapters; State = $state }
}

function New-CcodTask6DraftAdapterFixture {
    param([string]$AssetDirectory, [switch]$UploadFails, [switch]$UploadFailurePublishes, [switch]$ConcurrentStage, [switch]$ReadbackFails, [switch]$ReadbackFailurePublishes)
    $state = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        DraftPrivate = $true
        DraftId = '123'
        Created = $false
        Uploaded = [Collections.Generic.List[string]]::new()
        Promoted = $false
        Rebuilt = $false
        Assets = @{}
        SourceDirectory = $AssetDirectory
    }
    $hashFile = {
        param($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
            try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose() }
        } finally { $sha.Dispose() }
    }.GetNewClosure()
    $adapters = @{
        TryStageLock = { param($Tag) $state.Calls.Add('TryStageLock'); if ($ConcurrentStage) { $false } else { $true } }.GetNewClosure()
        CreateDraft = { param($Tag, $Title, $Notes) $state.Calls.Add('CreateDraft'); $state.Created = $true; $state.DraftPrivate = $true; [pscustomobject][ordered]@{ Tag = $Tag; Id = [string]$state.DraftId; Draft = $true; AssetNames = @() } }.GetNewClosure()
        GetTagCommit = { param($Tag, [bool]$ActionsOnly) $state.Calls.Add('GetTagCommit'); 'c' * 40 }.GetNewClosure()
        UploadAsset = { param($Tag, $Name, $Path)
            $state.Calls.Add('UploadAsset:' + $Name)
            if ($UploadFails) { if ($UploadFailurePublishes) { $state.DraftPrivate = $false }; throw 'upload failed' }
            $state.Uploaded.Add($Name)
            $state.Assets[$Name] = & $hashFile $Path
        }.GetNewClosure()
        DownloadAsset = { param($Tag, $Name, $Destination)
            $state.Calls.Add('DownloadAsset:' + $Name)
            if ($ReadbackFails) { if ($ReadbackFailurePublishes) { $state.DraftPrivate = $false }; throw 'readback failed' }
            $source = Join-Path $state.SourceDirectory $Name
            [IO.File]::Copy($source, $Destination, $true)
        }.GetNewClosure()
        ViewRelease = { param($Tag) $state.Calls.Add('ViewRelease'); [pscustomobject][ordered]@{ Tag = $Tag; Id = [string]$state.DraftId; Draft = [bool]$state.DraftPrivate; AssetNames = @($state.Uploaded) } }.GetNewClosure()
        ProbeRelease = { param($Tag) $state.Calls.Add('ProbeRelease'); $null }.GetNewClosure()
        SetReleaseDraftState = { param($Tag, [bool]$Draft) $state.Calls.Add('SetReleaseDraftState:' + $Draft); $state.DraftPrivate = [bool]$Draft; if (-not $Draft) { $state.Promoted = $true } }.GetNewClosure()
        InvokeBuild = { param($Version) $state.Calls.Add('InvokeBuild'); $state.Rebuilt = $true }.GetNewClosure()
        InvokeGh = { param($Arguments) $state.Calls.Add('InvokeGh'); throw 'raw gh forbidden' }.GetNewClosure()
    }
    [pscustomobject]@{ Adapters = $adapters; State = $state }
}

function Invoke-CcodTask6CleanCore {
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][hashtable]$Adapters)
    &$Module { param($RepositoryRoot,$ExpectedVersion,$Adapters) Test-CcodCleanReleaseRunnerCore -RepositoryRoot $RepositoryRoot -ExpectedVersion $ExpectedVersion -Adapters $Adapters } $RepositoryRoot $ExpectedVersion $Adapters
}

function Invoke-CcodTask6DraftCore {
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$Mode,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][hashtable]$Adapters,[string]$NotesPath)
        &$Module { param($Mode,$Tag,$AssetDirectory,$EvidenceDirectory,$Adapters,$NotesPath) Invoke-CcodGitHubDraftReleaseCore -Mode $Mode -Tag $Tag -AssetDirectory $AssetDirectory -EvidenceDirectory $EvidenceDirectory -Adapters $Adapters -NotesPath $NotesPath } $Mode $Tag $AssetDirectory $EvidenceDirectory $Adapters $NotesPath
}

Invoke-CcodTask6Test 'runner' 'clean release runner is exported from the production tool' {
    $path = Join-Path $repositoryRoot 'tools\Test-CleanReleaseRunner.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $path -PathType Leaf) 'clean release runner script exists'
    $module = Import-CcodTask6ToolModule -Path $path -Name 'CcodCleanReleaseRunnerPublic'
    try {
        $command = Get-Command Test-CcodCleanReleaseRunner -Module $module.Name -ErrorAction Stop
        Assert-CcodTrue ($command.Parameters.ContainsKey('RepositoryRoot')) 'clean runner requires RepositoryRoot'
        Assert-CcodTrue ($command.Parameters.ContainsKey('ExpectedVersion')) 'clean runner requires ExpectedVersion'
        Assert-CcodTrue (-not $command.Parameters.ContainsKey('Adapters')) 'public clean runner exposes no adapter injection parameter'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask6Test 'draft' 'draft release promoter is exported from the production tool' {
    $path = Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $path -PathType Leaf) 'draft release promoter script exists'
    $module = Import-CcodTask6ToolModule -Path $path -Name 'CcodGitHubDraftReleasePublic'
    try {
        $command = Get-Command Invoke-CcodGitHubDraftRelease -Module $module.Name -ErrorAction Stop
        foreach ($name in @('Mode','Tag','AssetDirectory','EvidenceDirectory')) {
            Assert-CcodTrue ($command.Parameters.ContainsKey($name)) "draft promoter requires $name"
        }
        Assert-CcodTrue (-not $command.Parameters.ContainsKey('Adapters')) 'public draft promoter exposes no adapter injection parameter'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask6Test 'pin' 'CI and release workflows pin checkout to the reviewed commit SHA' {
    $expected = 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262'
    foreach ($name in @('ci.yml','release.yml')) {
        $raw = [IO.File]::ReadAllText((Join-Path $repositoryRoot ('.github\workflows\' + $name)), [Text.UTF8Encoding]::new($false))
        Assert-CcodTrue ($raw.Contains($expected)) "$name pins actions/checkout to the reviewed SHA"
        Assert-CcodTrue ($raw -cnotmatch 'actions/checkout@v') "$name does not use a floating checkout tag"
    }
}

Invoke-CcodTask6Test 'glob' 'release workflow never uploads by dist glob or dotsources Defender library mode' {
    $raw = [IO.File]::ReadAllText((Join-Path $repositoryRoot '.github\workflows\release.yml'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($raw -cnotmatch 'build/dist/\*') 'release workflow does not upload by dist glob'
    Assert-CcodTrue ($raw -cnotmatch 'Test-ReleaseDefender\.ps1[^\r\n]*-Library') 'release workflow does not restore Defender library mode'
    Assert-CcodTrue ($raw.Contains('ReleaseAssetContract.psm1')) 'release workflow imports the central asset contract'
}

Invoke-CcodTask6Test 'draft-create' 'release workflow never public-first creates a GitHub release' {
    $raw = [IO.File]::ReadAllText((Join-Path $repositoryRoot '.github\workflows\release.yml'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($raw -cnotmatch '(?m)gh release create\b(?![^\r\n]*--draft)') 'gh release create is never invoked without --draft'
}

Invoke-CcodTask6Test 'workflow' 'CI and release workflows satisfy the draft-only pinned contract' {
    Assert-CcodDraftReleaseWorkflowContract `
        -CiPath (Join-Path $repositoryRoot '.github\workflows\ci.yml') `
        -ReleasePath (Join-Path $repositoryRoot '.github\workflows\release.yml')
}

Invoke-CcodTask6Test 'fix2-workflow-candidate-commit' 'Stage candidate gate rejects commits different from the immutable build output' {
    $path = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $raw = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
    $workflow = Get-CcodWorkflowStructure $path
    $stage = @($workflow.Jobs | Where-Object { $_.Name -ceq 'stage' })
    $step = @($stage[0].Steps | Where-Object { $_.Name -ceq 'Verify downloaded release candidate contract' })
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($step[0].Run, [ref]$tokens, [ref]$errors)
    $guards = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('$candidate.GitCommit') }, $true))
    Assert-CcodEqual 1 $guards.Count 'downloaded candidate has one executable commit guard'
    Assert-CcodTrue ($raw -cmatch '(?m)^          CCOD_RELEASE_COMMIT: \$\{\{ needs\.build\.outputs\.commit \}\}\r?$') 'commit guard consumes the immutable build output'
    $guard = [scriptblock]::Create($guards[0].Extent.Text)
    $saved = [Environment]::GetEnvironmentVariable('CCOD_RELEASE_COMMIT', 'Process')
    try {
        $candidate = [pscustomobject]@{ GitCommit = 'c' * 40 }
        $env:CCOD_RELEASE_COMMIT = 'c' * 40
        & $guard
        foreach ($invalid in @(('d' * 40), (('c' * 40) + "`n"), '')) {
            $env:CCOD_RELEASE_COMMIT = $invalid
            Assert-CcodThrows { & $guard } 'CCOD_RELEASE_BUILD_COMMIT_MISMATCH'
        }
    } finally { [Environment]::SetEnvironmentVariable('CCOD_RELEASE_COMMIT', $saved, 'Process') }
}

Invoke-CcodTask6Test 'fix2-workflow-authority' 'workflow contract rejects detached Stage checkout authority and skipped preflight transfer' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-workflow-authority-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $ci = Join-Path $repositoryRoot '.github\workflows\ci.yml'
        $releasePath = Join-Path $root 'release.yml'
        $raw = [IO.File]::ReadAllText((Join-Path $repositoryRoot '.github\workflows\release.yml'), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($releasePath, $raw, [Text.UTF8Encoding]::new($false))
        Assert-CcodDraftReleaseWorkflowContract -CiPath $ci -ReleasePath $releasePath
        $mutations = @(
            [pscustomobject]@{ Name = 'Stage dependency'; From = 'needs: build'; To = 'needs: preflight' }
            [pscustomobject]@{ Name = 'Stage immutable checkout'; From = 'ref: ${{ needs.build.outputs.commit }}'; To = 'ref: ${{ github.ref }}' }
            [pscustomobject]@{ Name = 'global write authority'; From = "permissions:`n  contents: read"; To = "permissions:`n  contents: write" }
            [pscustomobject]@{ Name = 'build write authority'; From = "  build:`n    needs: preflight"; To = "  build:`n    permissions:`n      contents: write`n    needs: preflight" }
            [pscustomobject]@{ Name = 'Stage write authority absent'; From = '      contents: write'; To = '      contents: read' }
            [pscustomobject]@{ Name = 'skipped preflight upload'; From = '      - name: Upload immutable clean preflight evidence'; To = "      - name: Upload immutable clean preflight evidence`n        if: false" }
            [pscustomobject]@{ Name = 'skipped preflight download'; From = '      - name: Download immutable clean preflight evidence'; To = "      - name: Download immutable clean preflight evidence`n        if: false" }
            [pscustomobject]@{ Name = 'skipped preflight materialization'; From = '      - name: Materialize transferred clean preflight evidence'; To = "      - name: Materialize transferred clean preflight evidence`n        if: false" }
        )
        $normalized = $raw.Replace("`r`n", "`n")
        foreach ($mutation in $mutations) {
            $changed = $normalized.Replace($mutation.From, $mutation.To)
            Assert-CcodTrue ($changed -cne $normalized) "$($mutation.Name) mutation reaches the real workflow"
            [IO.File]::WriteAllText($releasePath, $changed, [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { Assert-CcodDraftReleaseWorkflowContract -CiPath $ci -ReleasePath $releasePath } 'CCOD_RELEASE_WORKFLOW_INVALID'
        }
    } finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}

Invoke-CcodTask6Test 'workflow-bypass' 'draft workflow contract rejects unpinned actions continue-on-error if-bypass rebuild and missing concurrency' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-workflow-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $ciPath = Join-Path $root 'ci.yml'
        $releasePath = Join-Path $root 'release.yml'
        $pinnedCi = @'
name: fixture CI
jobs:
  validate:
    steps:
      - name: Check out repository
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
      - name: Set up Node.js
        uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020
'@
        $pinnedRelease = [IO.File]::ReadAllText((Join-Path $repositoryRoot '.github/workflows/release.yml'), [Text.UTF8Encoding]::new($false)).Replace("`r`n", "`n")
        [IO.File]::WriteAllText($ciPath, $pinnedCi, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($releasePath, $pinnedRelease, [Text.UTF8Encoding]::new($false))
        Assert-CcodDraftReleaseWorkflowContract -CiPath $ciPath -ReleasePath $releasePath
        $invalid = @(
            [pscustomobject]@{ Name = 'unpinned setup-node'; Release = $pinnedRelease.Replace('actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020','actions/setup-node@v4') },
            [pscustomobject]@{ Name = 'continue-on-error'; Release = $pinnedRelease.Replace('      - name: Run clean release runner',"      - name: Run clean release runner`n        continue-on-error: true") },
            [pscustomobject]@{ Name = 'if bypass'; Release = $pinnedRelease.Replace('      - name: Run clean release runner', '      - name: Run clean release runner' + "`n" + '        if: ${{ false }}') },
            [pscustomobject]@{ Name = 'missing concurrency'; Release = [regex]::Replace($pinnedRelease, '(?m)^concurrency:\n  group:[^\n]+\n  cancel-in-progress: false\n', '') },
            [pscustomobject]@{ Name = 'rebuild in stage'; Release = $pinnedRelease + [Environment]::NewLine + "        run: ./build/build.ps1 -Version 2.5.22`n" },
            [pscustomobject]@{ Name = 'extension glob'; Release = $pinnedRelease.Replace('Get-CcodExpectedReleaseAssetNames -Version $version','Get-ChildItem -File | Where-Object { $_.Extension -in @(''.exe'') }') }
        )
        foreach ($fixture in $invalid) {
            Assert-CcodTrue ($fixture.Release -cne $pinnedRelease) "$($fixture.Name) mutation changes the workflow"
            [IO.File]::WriteAllText($releasePath, [string]$fixture.Release, [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { Assert-CcodDraftReleaseWorkflowContract -CiPath $ciPath -ReleasePath $releasePath } 'CCOD_RELEASE_WORKFLOW_INVALID'
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'runner-core' 'clean runner core accepts module-scope adapters and public surface does not' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Test-CleanReleaseRunner.ps1') -Name 'CcodCleanReleaseRunner'
    try {
        $public = Get-Command Test-CcodCleanReleaseRunner -Module $module.Name -ErrorAction Stop
        Assert-CcodTrue (-not $public.Parameters.ContainsKey('Adapters')) 'public clean runner exposes no adapter injection parameter'
        $core = &$module { Get-Command Test-CcodCleanReleaseRunnerCore -ErrorAction SilentlyContinue }
        Assert-CcodTrue ($null -ne $core) 'clean runner core exists for tests'
        Assert-CcodTrue ($core.Parameters.ContainsKey('Adapters')) 'clean runner core accepts adapters'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask6Test 'runner-reject' 'clean runner fail-closes contaminated dirty missing-preflight and version mismatches without cleanup' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Test-CleanReleaseRunner.ps1') -Name 'CcodCleanReleaseRunner'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-clean-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        foreach ($case in @(
            [pscustomobject]@{ Id = 'installed'; Error = 'CCOD_CLEAN_RUNNER_CONTAMINATED'; Fixture = { New-CcodTask6CleanAdapterFixture -Installed } },
            [pscustomobject]@{ Id = 'mutex'; Error = 'CCOD_CLEAN_RUNNER_CONTAMINATED'; Fixture = { New-CcodTask6CleanAdapterFixture -MutexOccupied } },
            [pscustomobject]@{ Id = 'task'; Error = 'CCOD_CLEAN_RUNNER_CONTAMINATED'; Fixture = { New-CcodTask6CleanAdapterFixture -TaskPresent } },
            [pscustomobject]@{ Id = 'supervisor'; Error = 'CCOD_CLEAN_RUNNER_CONTAMINATED'; Fixture = { New-CcodTask6CleanAdapterFixture -SupervisorPresent } },
            [pscustomobject]@{ Id = 'trayhost'; Error = 'CCOD_CLEAN_RUNNER_CONTAMINATED'; Fixture = { New-CcodTask6CleanAdapterFixture -TrayHostPresent } },
            [pscustomobject]@{ Id = 'dirty'; Error = 'CCOD_CLEAN_RUNNER_DIRTY'; Fixture = { New-CcodTask6CleanAdapterFixture -Porcelain ' M README.md' } },
            [pscustomobject]@{ Id = 'version'; Error = 'CCOD_CLEAN_RUNNER_VERSION_INVALID'; Fixture = { New-CcodTask6CleanAdapterFixture -Version '2.5.21' } }
        )) {
            $fixture = & $case.Fixture
            Assert-CcodThrows { Invoke-CcodTask6CleanCore -Module $module -RepositoryRoot $root -ExpectedVersion '2.5.22' -Adapters $fixture.Adapters | Out-Null } $case.Error
            Assert-CcodEqual 0 $fixture.State.Cleanup.Count "clean runner does not cleanup after $($case.Id)"
        }
        $ok = New-CcodTask6CleanAdapterFixture
        $result = Invoke-CcodTask6CleanCore -Module $module -RepositoryRoot $root -ExpectedVersion '2.5.22' -Adapters $ok.Adapters
        Assert-CcodTrue ([bool]$result.Valid) 'clean runner accepts a clean checkout'
        Assert-CcodEqual '2.5.22' ([string]$result.Version) 'clean runner returns the expected version'
        Assert-CcodTrue ($ok.State.Calls -contains 'WritePreflightEvidence') 'clean runner writes preflight evidence'
        Assert-CcodEqual 0 $ok.State.Cleanup.Count 'successful clean runner still performs no cleanup'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'draft-core' 'draft promoter core accepts module-scope adapters and public surface does not' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftRelease'
    try {
        $public = Get-Command Invoke-CcodGitHubDraftRelease -Module $module.Name -ErrorAction Stop
        Assert-CcodTrue (-not $public.Parameters.ContainsKey('Adapters')) 'public draft promoter exposes no adapter injection parameter'
        $core = &$module { Get-Command Invoke-CcodGitHubDraftReleaseCore -ErrorAction SilentlyContinue }
        Assert-CcodTrue ($null -ne $core) 'draft promoter core exists for tests'
        Assert-CcodTrue ($core.Parameters.ContainsKey('Adapters')) 'draft promoter core accepts adapters'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask6Test 'fix1-public-module-boundary' 'release workflow imports only the public draft command and does not dot-source injectable internals' {
    $releasePath = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $workflow = [IO.File]::ReadAllText($releasePath, [Text.UTF8Encoding]::new($false))
    foreach ($spec in @(
        [pscustomobject]@{ Name = 'draft'; Script = 'Invoke-GitHubDraftRelease.psm1'; Public = 'Invoke-CcodGitHubDraftRelease'; Private = 'Invoke-CcodGitHubDraftReleaseCore' },
        [pscustomobject]@{ Name = 'clean runner'; Script = 'Test-CleanReleaseRunner.psm1'; Public = 'Test-CcodCleanReleaseRunner'; Private = 'Test-CcodCleanReleaseRunnerCore' }
    )) {
        $scriptPath = Join-Path $repositoryRoot ('tools/' + $spec.Script)
        Assert-CcodTrue (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$($spec.Name) tool has a real module wrapper"
        Assert-CcodTrue ($workflow -cmatch ('Import-Module.*' + [regex]::Escape($spec.Script))) "$($spec.Name) workflow import uses the module wrapper"
        Assert-CcodTrue ($workflow -cnotmatch ('(?m)^\s*\.\s+\.?/?\.?[/\\]tools[/\\]' + [regex]::Escape($spec.Script))) "$($spec.Name) workflow does not dot-source the module wrapper"
        $module = Import-Module $scriptPath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodTrue ($null -ne (Get-Command $spec.Public -Module $module.Name -ErrorAction SilentlyContinue)) "$($spec.Name) public command is exported"
            Assert-CcodTrue ($null -eq (Get-Command $spec.Private -Module $module.Name -ErrorAction SilentlyContinue)) "$($spec.Name) private core is not exported"
        } finally {
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-CcodTask6Test 'fix1-fresh-process-module-boundary' 'draft release wrapper exports only its public command in a fresh PowerShell process' {
    $wrapper = Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.psm1'
    Assert-CcodTrue (Test-Path -LiteralPath $wrapper -PathType Leaf) 'draft release wrapper exists as a regular file'
    $escaped = $wrapper.Replace("'", "''")
    $probe = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'; if ((Get-ExecutionPolicy -Scope Process) -cne 'Undefined' -or -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process'))) { exit 24 }; Import-Module '$escaped' -Force; `$public = Get-Command Invoke-CcodGitHubDraftRelease -ErrorAction SilentlyContinue; `$private = Get-Command Invoke-CcodGitHubDraftReleaseCore -ErrorAction SilentlyContinue; if (`$null -eq `$public -or `$null -ne `$private) { exit 23 }; [Console]::WriteLine('CCOD_DRAFT_WRAPPER_POLICY=' + (Get-ExecutionPolicy)); [Console]::WriteLine('CCOD_DRAFT_WRAPPER_OK')"
    $previous=[Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process')
    $normalPolicy=$null
    try {
        foreach($inherited in @($null,'Bypass','Restricted')) {
            [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference',$inherited,'Process')
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=(Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
            $info.Arguments='-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $info.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
            Assert-CcodTrue (-not$info.EnvironmentVariables.ContainsKey('PSExecutionPolicyPreference')) 'actual child environment excludes the parent policy override'
            Assert-CcodEqual ('-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded) $info.Arguments 'actual child arguments contain no policy override'
            $child=[Diagnostics.Process]::new();$child.StartInfo=$info;$started=$false
            try {
                $started=$child.Start()
                Assert-CcodTrue $started 'fresh wrapper process actually starts'
                $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
                Assert-CcodTrue ($child.WaitForExit(60000)) 'fresh wrapper process completes within the timeout'
                $output=$stdout.GetAwaiter().GetResult();$errorOutput=$stderr.GetAwaiter().GetResult()
                Assert-CcodEqual 0 $child.ExitCode "fresh PowerShell import uses normal process policy with parent override '$inherited'"
                Assert-CcodEqual '' $errorOutput 'normal-policy module import has no stderr failure'
                Assert-CcodTrue $output.Contains('CCOD_DRAFT_WRAPPER_OK') 'fresh PowerShell import exports the expected public command'
                $policyLines=@($output.Split([char]10)|Where-Object {$_.StartsWith('CCOD_DRAFT_WRAPPER_POLICY=',[StringComparison]::Ordinal)})
                Assert-CcodEqual 1 $policyLines.Count 'the real child reports exactly one effective policy'
                $policyValue=$policyLines[0].TrimEnd([char]13).Substring('CCOD_DRAFT_WRAPPER_POLICY='.Length)
                Assert-CcodTrue (-not[string]::IsNullOrWhiteSpace($policyValue)) 'effective policy is not empty'
                if($null-eq$normalPolicy){$normalPolicy=$policyValue}else{Assert-CcodEqual $normalPolicy $policyValue 'parent override does not change the actual normal child policy'}
                Assert-CcodEqual $inherited ([Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process')) 'launch configuration does not mutate the parent environment'
            } finally {if($started-and-not$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
        }
    } finally {[Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference',$previous,'Process')}
    Assert-CcodEqual $previous ([Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process')) 'test restores its original parent environment'
}

Invoke-CcodTask6Test 'draft-stage' 'Stage fail-closes missing preflight extra assets upload failure concurrent stage and never promotes' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftRelease'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-draft-' + [guid]::NewGuid().ToString('N'))
    $assetFixture = $null
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $evidence = Join-Path $root 'evidence'
        [IO.Directory]::CreateDirectory($evidence) | Out-Null
        $emptyAssets = Join-Path $root 'assets'
        [IO.Directory]::CreateDirectory($emptyAssets) | Out-Null
        $fixture = New-CcodTask6DraftAdapterFixture -AssetDirectory $emptyAssets
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $emptyAssets -EvidenceDirectory $evidence -Adapters $fixture.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING'
        Assert-CcodTrue (-not $fixture.State.Promoted) 'missing preflight never promotes'
        Assert-CcodTrue (-not $fixture.State.Rebuilt) 'missing preflight never rebuilds'
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), '{"valid":true}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $emptyAssets 'unexpected.txt'), 'x', [Text.UTF8Encoding]::new($false))
        $extra = New-CcodTask6DraftAdapterFixture -AssetDirectory $emptyAssets
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $emptyAssets -EvidenceDirectory $evidence -Adapters $extra.Adapters | Out-Null } 'CCOD_RELEASE_ASSET_SET_INVALID'
        Assert-CcodTrue (-not $extra.State.Promoted) 'extra asset never promotes'
        $assetFixture = New-CcodTask5ExactAssetFixture
        $preflight = Join-Path $assetFixture.Outside 'CodexRemote-fix-2.5.22-clean-preflight.json'
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText($preflight, (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $upload = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root -UploadFails -UploadFailurePublishes
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $assetFixture.Outside -Adapters $upload.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED'
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory 'relative-assets' -EvidenceDirectory $assetFixture.Outside -Adapters $upload.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_ASSET_PATH_INVALID'
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory 'relative-evidence' -Adapters $upload.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID'
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $assetFixture.Outside -NotesPath 'tests/persistence/ReleaseWorkflow.SelfTest.ps1' -Adapters $upload.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_NOTES_INVALID'
        Assert-CcodTrue $upload.State.Created 'upload failure still created a draft'
        Assert-CcodTrue $upload.State.DraftPrivate 'upload failure leaves the draft private'
        Assert-CcodTrue (-not $upload.State.Promoted) 'upload failure never promotes'
        $busy = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root -ConcurrentStage
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $assetFixture.Outside -Adapters $busy.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_CONCURRENT'
        Assert-CcodTrue (-not $busy.State.Created) 'concurrent stage does not create a second draft'
        Assert-CcodTrue (-not $busy.State.Promoted) 'concurrent stage never promotes'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'draft-verify-promote' 'Verify and Promote cannot rebuild and Promote fail-closes missing dual receipt or acceptance' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftRelease'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $verify = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $verify.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_NOT_STAGED'
        Assert-CcodTrue (-not $verify.State.Rebuilt) 'Verify never rebuilds'
        Assert-CcodTrue (-not $verify.State.Created) 'Verify never creates a release'
        Assert-CcodTrue (-not $verify.State.Promoted) 'Verify never promotes'
        $promote = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        [IO.Directory]::CreateDirectory((Join-Path $evidence 'defender')) | Out-Null
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $promote.Adapters | Out-Null } 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
        Assert-CcodTrue (-not $promote.State.Promoted) 'missing dual receipt never promotes'
        Assert-CcodTrue (-not $promote.State.Rebuilt) 'Promote never rebuilds'
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $promoteEvidence = $promotion.Root
        $defender = Join-Path $promoteEvidence 'defender'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promoteEvidence $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promoteEvidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $missingAcceptance = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promoteEvidence -Adapters $missingAcceptance.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_MISSING'
        Assert-CcodTrue (-not $missingAcceptance.State.Promoted) 'missing acceptance never promotes'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'task9-promote-incomplete' 'Promote rejects the legacy acceptance envelope before changing draft visibility' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseTask9PromoteIncomplete'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) {
            Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name)
        }
        $preflightRecord = [ordered]@{
            schemaVersion = 1
            valid = $true
            version = '2.5.22'
            gitCommit = [string]$assetFixture.GitCommit
            repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot)
        }
        [IO.File]::WriteAllText(
            (Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'),
            (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false))
        $expected = [string[]]$assetFixture.Names
        $fixture = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $fixture.State.Uploaded.AddRange($expected)
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $fixture.Adapters | Out-Null
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        $legacyAcceptance = [ordered]@{
            schemaVersion = 1
            kind = 'official-draft-acceptance'
            version = '2.5.22'
            gitCommit = [string]$assetFixture.GitCommit
            candidateManifestSha256 = Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $assetFixture.Names[4])
            phase = 'Complete'
            completedAtUtc = '2030-02-03T04:05:07.0000000Z'
        }
        [IO.File]::WriteAllText(
            (Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'),
            (($legacyAcceptance | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $fixture.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INCOMPLETE'
        Assert-CcodTrue (-not $fixture.State.Promoted) 'incomplete acceptance never changes draft visibility'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-runner-inspection' 'clean runner converts inspection failures into stable fail-closed errors' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Test-CleanReleaseRunner.ps1') -Name 'CcodCleanReleaseRunnerFix1Inspection'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-runner-inspection-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $fixture = New-CcodTask6CleanAdapterFixture
        $fixture.Adapters.GetGitPorcelain = { param($Root) throw 'git inspection unavailable' }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6CleanCore -Module $module -RepositoryRoot $root -ExpectedVersion '2.5.22' -Adapters $fixture.Adapters | Out-Null } 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED'
        Assert-CcodEqual 0 $fixture.State.Cleanup.Count 'git inspection failure does not invoke cleanup'
        $fixture = New-CcodTask6CleanAdapterFixture
        $fixture.Adapters.GetProductState = { param($Root) throw 'product inspection denied' }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6CleanCore -Module $module -RepositoryRoot $root -ExpectedVersion '2.5.22' -Adapters $fixture.Adapters | Out-Null } 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED'
        Assert-CcodEqual 0 $fixture.State.Cleanup.Count 'product inspection failure does not invoke cleanup'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-preflight-binding' 'Stage rejects an unbound or malformed transferred clean preflight before creating a draft' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1Preflight'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflight = Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'
        $record = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.21'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText($preflight, (($record | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $fixture = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $fixture.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID'
        Assert-CcodTrue (-not $fixture.State.Created) 'invalid preflight does not create a draft'
        Assert-CcodTrue (-not $fixture.State.Promoted) 'invalid preflight does not promote'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-preflight-all-modes' 'Verify and Promote require the transferred clean preflight before accepting or publishing evidence' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1PreflightAllModes'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = Join-Path $assetFixture.Outside 'verify-without-preflight'
        [IO.Directory]::CreateDirectory($evidence) | Out-Null
        $expected = [string[]]$assetFixture.Names
        $verify = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $verify.State.Uploaded.AddRange($expected)
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $verify.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $evidence 'verification') -PathType Container)) 'Verify without preflight writes no verification evidence'

        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $verificationDirectory = Join-Path $promotion.Root 'verification'
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightPath = Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText($preflightPath, (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $promote = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $promote.State.Uploaded.AddRange($expected)
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $promote.Adapters | Out-Null
        Remove-Item -LiteralPath $preflightPath -Force
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $promote.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING'
        Assert-CcodTrue (-not $promote.State.Promoted) 'Promote without preflight never changes visibility'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-remote-contract' 'Verify rejects null, public, and non-exact remote draft responses' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1Remote'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $expected = @(Get-CcodTask5ExpectedAssetNames '2.5.22')
        $nullView = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $nullView.Adapters.ViewRelease = { param($Tag) $null }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $nullView.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_NOT_STAGED'
        $publicView = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $publicView.State.Uploaded.AddRange([string[]]$expected)
        $publicView.State.DraftPrivate = $false
        $publicView.Adapters.ViewRelease = { param($Tag) [pscustomobject][ordered]@{ Tag = $Tag; Id = '123'; Draft = $false; AssetNames = @($expected) } }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $publicView.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_NOT_STAGED'
        $wrongNames = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $wrong = @($expected)
        $wrong[0] = 'unexpected-release-asset.zip'
        $wrongNames.State.Uploaded.AddRange([string[]]$wrong)
        $wrongNames.Adapters.ViewRelease = { param($Tag) [pscustomobject][ordered]@{ Tag = $Tag; Id = '123'; Draft = $true; AssetNames = @($wrong) } }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $wrongNames.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_ASSET_SET_INVALID'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-verify-final-remote-lineage' 'Verify rechecks private draft identity and tag commit after the last asset download' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1VerifyFinalLineage'
    $assetFixture = $null;$evidence = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture;$evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $expected = [string[]]$assetFixture.Names;$remoteRoot = Join-Path $assetFixture.Outside 'verify-remote-assets';[IO.Directory]::CreateDirectory($remoteRoot) | Out-Null
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root;$state = $draft.State;$state.Uploaded.AddRange($expected);$state | Add-Member -NotePropertyName DownloadCount -NotePropertyValue 0
        $draft.Adapters.ViewRelease = { param($Tag) [pscustomobject][ordered]@{ Tag = $Tag; Id = [string]$state.DraftId; Draft = [bool]$state.DraftPrivate; AssetNames = @($state.Uploaded) } }.GetNewClosure()
        $draft.Adapters.DownloadAsset = { param($Tag,$Name,$Destination) [IO.File]::Copy((Join-Path $assetFixture.Root $Name),$Destination,$true);$state.DownloadCount++ }.GetNewClosure()
        $verificationPath = & $module {param($Evidence) Get-CcodGitHubDraftVerificationPath -EvidenceDirectory $Evidence -Version '2.5.22'} $evidence
        $control=Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters
        Assert-CcodEqual $verificationPath $control.VerificationPath 'absence probe points at the proven real publisher destination'
        Assert-CcodTrue ([IO.File]::Exists($verificationPath)) 'success control materializes the exact target before absence checks'
        [IO.File]::Delete($verificationPath);$state.DownloadCount=0
        $draft.Adapters.DownloadAsset = { param($Tag,$Name,$Destination) [IO.File]::Copy((Join-Path $assetFixture.Root $Name),$Destination,$true);$state.DownloadCount++;if($state.DownloadCount -eq $expected.Count){$state.DraftPrivate=$false} }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID'
        Assert-CcodEqual $expected.Count $state.DownloadCount 'Verify downloaded every asset before the final remote recheck'
        Assert-CcodTrue (-not [IO.File]::Exists($verificationPath)) 'Verify does not publish evidence after a final remote identity drift'
    } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue;if($null -ne $assetFixture){Remove-CcodTask5ExactAssetFixture $assetFixture} }
}

Invoke-CcodTask6Test 'fix1-github-boundary' 'draft release operations are bound to the official Actions repository without an environment bypass' {
    $draftPath = Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'
    $releasePath = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $draftRaw = [IO.File]::ReadAllText($draftPath, [Text.UTF8Encoding]::new($false))
    $releaseRaw = [IO.File]::ReadAllText($releasePath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue (-not ($draftRaw + $releaseRaw).Contains('CCOD_ALLOW_GITHUB_RELEASE')) 'live GitHub operations have no caller-controlled override'
    Assert-CcodTrue ($draftRaw.Contains('naipi11/CodexRemote-fix')) 'GitHub target repository is explicit'
    Assert-CcodTrue ($draftRaw.Contains('GITHUB_SERVER_URL') -and $draftRaw.Contains('GITHUB_RUN_ID') -and $draftRaw.Contains('GH_TOKEN')) 'default GitHub adapter checks the Actions context'
    Assert-CcodTrue ($draftRaw.Contains("GITHUB_RUN_ID -notmatch '^[1-9][0-9]*\z'")) 'Actions run IDs use an absolute end anchor'
    Assert-CcodTrue ($draftRaw.Contains('$value.isDraft -isnot [bool]')) 'default GitHub adapter rejects non-boolean draft state'
    Assert-CcodTrue ($draftRaw.Contains("'tagName,isDraft,databaseId,assets'")) 'default GitHub adapter requests a stable draft database identity'
    Assert-CcodTrue ($draftRaw.Contains('$json -join [Environment]::NewLine')) 'default GitHub adapter parses the complete multi-line JSON response'
    $ghLines = @($draftRaw -split "`r?`n" | Where-Object { $_ -match '& gh ' })
    Assert-CcodTrue ($ghLines.Count -gt 0) 'default adapter has explicit GitHub operations'
    foreach ($line in $ghLines) {
        if ($line -match '& gh api') {
            Assert-CcodTrue ($draftRaw.Contains('repos/naipi11/CodexRemote-fix/')) 'GitHub API operation pins the repository in its endpoint'
        } elseif ($line -notmatch '& gh auth status') {
            Assert-CcodTrue ($line.Contains('--repo')) 'every GitHub release operation pins the repository'
        }
        if ($line -notmatch '\$json\s*=\s*& gh ' -and $line -notmatch '& gh api ') { Assert-CcodTrue ($line.Contains('| Out-Null')) 'non-query GitHub operations do not leak CLI output into the state result' }
    }
}

Invoke-CcodTask6Test 'fix1-local-promote-context' 'authenticated local draft readback does not require the GitHub Actions environment' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1LocalContext'
    $fakeRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-local-gh-' + [guid]::NewGuid().ToString('N'))
    $fakeGh = Join-Path $fakeRoot 'gh.cmd'
    $saved = @{}
    try {
        [IO.Directory]::CreateDirectory($fakeRoot) | Out-Null
        [IO.File]::WriteAllText($fakeGh, "@echo off`r`nif `"%1`"==`"release`" if `"%2`"==`"view`" (`r`n  echo {`"tagName`":`"v2.5.22`",`"isDraft`":true,`"databaseId`":123,`"assets`":[]}`r`n)`r`nexit /b 0`r`n", [Text.UTF8Encoding]::new($false))
        foreach ($name in @('GITHUB_ACTIONS','GITHUB_SERVER_URL','GITHUB_REPOSITORY','GITHUB_RUN_ID','GH_TOKEN','Path')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        Remove-Item Env:GITHUB_ACTIONS,Env:GITHUB_SERVER_URL,Env:GITHUB_REPOSITORY,Env:GITHUB_RUN_ID -ErrorAction SilentlyContinue
        $env:GH_TOKEN = 'x'
        $env:Path = $fakeRoot + ';' + $saved.Path
        $view = &$module { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.ViewRelease 'v2.5.22' }
        Assert-CcodTrue ($view.Draft -is [bool] -and $view.Draft) 'local authenticated draft readback is allowed without Actions context'
    } finally {
        foreach ($name in @('GITHUB_ACTIONS','GITHUB_SERVER_URL','GITHUB_REPOSITORY','GITHUB_RUN_ID','GH_TOKEN','Path')) {
            if ($null -eq $saved[$name]) { Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue } else { Set-Item ("Env:" + $name) $saved[$name] }
        }
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $fakeRoot) { Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-pwsh-schema-version' 'preflight schemaVersion accepts the Int64 representation emitted by PowerShell Core' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1PwshSchema'
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-pwsh-schema-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($path, '{}', [Text.UTF8Encoding]::new($false))
        $record = [pscustomobject][ordered]@{
            schemaVersion = [int64]1
            valid = $true
            version = '2.5.22'
            gitCommit = 'c' * 40
            repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot)
        }
        &$module { param($Value) Set-Item Function:Read-CcodGitHubDraftContractJson -Value { param($JsonPath,$ErrorId) [pscustomobject]@{ Raw = '{}'; Value = $Value } }.GetNewClosure() } $record
        $result = &$module { param($Path,$Version,$Commit) Read-CcodGitHubDraftPreflight -Path $Path -Version $Version -GitCommit $Commit } $path '2.5.22' ('c' * 40)
        Assert-CcodEqual 1 ([long]$result.schemaVersion) 'PowerShell Core Int64 schemaVersion is accepted'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-release-contract-int64-numeric-fields' 'release Defender receipts accept the Int64 numeric representation emitted by PowerShell Core' {
    $module = Import-Module $assetContractPath -Force -PassThru -ErrorAction Stop
    $version = '2.5.22'
    $commit = 'c' * 40
    $names = @(&$module { param($Version) Get-CcodExpectedReleaseAssetNames -Version $Version } $version)
    $scanStart = [datetime]::UtcNow.AddMinutes(-1)
    $timestamp = $scanStart.ToString('o')
    $completedTimestamp = $scanStart.AddSeconds(1).ToString('o')
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = [int64]2
        assetType = 'PortableZip'
        assetName = $names[0]
        assetSha256 = '0' * 64
        checksumName = $names[1]
        checksumSha256 = '1' * 64
        manifestName = $names[4]
        manifestSha256 = '2' * 64
        version = $version
        gitCommit = $commit
        origin = 'InternetDownload'
        workflowArtifactIdentity = $null
        zoneId = [int64]3
        defenderServiceEnabled = $true
        antivirusEnabled = $true
        realTimeProtectionEnabled = $true
        defenderPlatformVersion = 'fixture-platform'
        defenderEngineVersion = 'fixture-engine'
        signatureVersion = 'fixture-signature'
        signatureUpdatedAtUtc = $timestamp
        scanStartedAtUtc = $timestamp
        scanCompletedAtUtc = $completedTimestamp
        detectionCount = [int64]0
        outcome = 'Completed'
        errorCode = $null
    }
    $raw = $receipt | ConvertTo-Json -Compress -Depth 8
    try {
        $validated = &$module { param($Receipt,$Raw,$Version,$Commit,$Names) Test-CcodReleasePromotionReceipt -Receipt $Receipt -Raw $Raw -Path 'fixture-receipt.json' -AssetType 'PortableZip' -Version $Version -GitCommit $Commit -AssetNames $Names } $receipt $raw $version $commit $names
        Assert-CcodEqual 2 ([long]$validated.schemaVersion) 'PowerShell Core Int64 Defender receipt schemaVersion is accepted'
        Assert-CcodEqual 3 ([long]$validated.zoneId) 'PowerShell Core Int64 Defender receipt zoneId is accepted'
        Assert-CcodEqual 0 ([long]$validated.detectionCount) 'PowerShell Core Int64 Defender receipt detectionCount is accepted'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask6Test 'fix1-release-manifest-int64-dispatch' 'release manifests dispatch Int64 schemaVersion values to the portable validator' {
    $module = Import-Module $assetContractPath -Force -PassThru -ErrorAction Stop
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-manifest-dispatch-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $manifestPath = Join-Path $root 'manifest.json'
        [IO.File]::WriteAllText($manifestPath, '{}', [Text.UTF8Encoding]::new($false))
        $global:CcodReleaseManifestDispatchValue = [pscustomobject][ordered]@{ schemaVersion = [int64]2 }
        $global:CcodReleaseManifestDispatchMarker = $null
        &$module {
            Set-Item Function:Read-CcodReleaseContractJson -Value { param($Path,$ErrorId) [pscustomobject]@{ Raw = '{}'; Value = $global:CcodReleaseManifestDispatchValue } }
            Set-Item Function:Test-CcodReleasePortableManifestDeep -Value { param($Manifest,$ManifestRaw,$ManifestPath,$Directory,$Version,$ErrorId) $global:CcodReleaseManifestDispatchMarker = 'portable'; [pscustomobject]@{ Marker = 'portable' } }
        }
        $result = &$module { param($ManifestPath,$AssetDirectory) Test-CcodReleaseAssetManifest -ManifestPath $ManifestPath -AssetDirectory $AssetDirectory -ExpectedVersion '2.5.22' } $manifestPath $root
        Assert-CcodEqual 'portable' ([string]$result.Marker) 'Int64 schemaVersion dispatches to the portable manifest validator'
        Assert-CcodEqual 'portable' ([string]$global:CcodReleaseManifestDispatchMarker) 'portable dispatch marker is reached'
    } finally {
        Remove-Variable -Name CcodReleaseManifestDispatchValue,CcodReleaseManifestDispatchMarker -Scope Global -ErrorAction SilentlyContinue
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-preflight-root-canonical' 'preflight rejects drive-relative repository roots' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1PreflightRoot'
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-preflight-root-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($path, '{}', [Text.UTF8Encoding]::new($false))
        $record = [pscustomobject][ordered]@{
            schemaVersion = 1
            valid = $true
            version = '2.5.22'
            gitCommit = 'c' * 40
            repositoryRoot = 'C:relative-root'
        }
        &$module { param($Value) Set-Item Function:Read-CcodGitHubDraftContractJson -Value { param($JsonPath,$ErrorId) [pscustomobject]@{ Raw = '{}'; Value = $Value } }.GetNewClosure() } $record
        Assert-CcodThrows {
            &$module { param($Path,$Version,$Commit) Read-CcodGitHubDraftPreflight -Path $Path -Version $Version -GitCommit $Commit } $path '2.5.22' ('c' * 40)
        } 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-install-root-probe' 'clean runner treats a file at the install root as product state and distinguishes absence' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Test-CleanReleaseRunner.ps1') -Name 'CcodCleanReleaseRunnerFix1InstallRoot'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-install-root-' + [guid]::NewGuid().ToString('N'))
    $file = Join-Path $root 'malformed-install-root'
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText($file, 'not-a-directory', [Text.UTF8Encoding]::new($false))
        $present = &$module { param($Path) Get-CcodCleanReleaseRunnerInstallRootPresent -InstallRoot $Path } $file
        $missing = &$module { param($Path) Get-CcodCleanReleaseRunnerInstallRootPresent -InstallRoot $Path } (Join-Path $root 'missing')
        Assert-CcodTrue ([bool]$present) 'existing file at install root is treated as present'
        Assert-CcodEqual $false ([bool]$missing) 'missing install root is treated as absent'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-ignored-clean-runner' 'clean runner includes ignored files in the contamination check' {
    $raw = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Test-CleanReleaseRunner.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($raw.Contains('--ignored=matching')) 'clean runner asks git status to report ignored contamination'
}

Invoke-CcodTask6Test 'fix1-mode-normalization' 'case-insensitive mode binding dispatches lowercase verify to Verify rather than Stage' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1Mode'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        foreach ($name in @($assetFixture.Names)) { $draft.State.Uploaded.Add($name) }
        $result = Invoke-CcodTask6DraftCore -Module $module -Mode 'verify' -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters
        Assert-CcodEqual 'Verify' ([string]$result.Mode) 'lowercase verify dispatches to the Verify mode'
        Assert-CcodEqual 0 (@($draft.State.Calls | Where-Object { $_ -eq 'CreateDraft' }).Count) 'lowercase verify does not create a release'
        Assert-CcodEqual 0 (@($draft.State.Calls | Where-Object { [string]$_ -like 'UploadAsset:*' }).Count) 'lowercase verify does not upload assets'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-tag-commit-binding' 'release operations bind the remote tag to the immutable candidate commit' {
    $draft = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($draft.Contains('GetTagCommit')) 'draft tool resolves the remote tag commit'
    Assert-CcodTrue ($draft.Contains('repos/naipi11/CodexRemote-fix/commits/')) 'tag resolution is bound to the official repository'
    Assert-CcodTrue ($draft.Contains("'--verify-tag'")) 'draft creation verifies the existing remote tag'
}

Invoke-CcodTask6Test 'fix1-create-private-readback' 'Stage confirms the newly created release is still private before uploading the first asset' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1CreatePrivate'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null
        $firstUpload = @($draft.State.Calls | Where-Object { [string]$_ -like 'UploadAsset:*' })[0]
        $firstUploadIndex = [array]::IndexOf([string[]]$draft.State.Calls, [string]$firstUpload)
        $firstViewIndex = [array]::IndexOf([string[]]$draft.State.Calls, 'ViewRelease')
        Assert-CcodTrue ($firstViewIndex -ge 0 -and $firstViewIndex -lt $firstUploadIndex) 'private release state is read before the first asset upload'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-stage-readback-private-recovery' 'Stage reasserts private visibility when post-upload asset readback fails' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1StageReadback'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root -ReadbackFails -ReadbackFailurePublishes
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
        Assert-CcodTrue $draft.State.DraftPrivate 'post-upload readback failure restores private draft visibility'
        Assert-CcodTrue (-not $draft.State.Promoted) 'post-upload readback failure never promotes'
        $viewCalls = @($draft.State.Calls | Where-Object { $_ -eq 'ViewRelease' })
        Assert-CcodTrue ($viewCalls.Count -ge 3) 'post-upload readback failure performs a recovery state readback'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-stage-final-private-readback' 'Stage rejects a visibility change after the final asset readback' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1StageFinalPrivate'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $draft.Adapters.DownloadAsset = {
            param($Tag, $Name, $Destination)
            [IO.File]::Copy((Join-Path $assetFixture.Root $Name), $Destination, $true)
            $draft.State.DraftPrivate = $false
        }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_NOT_STAGED'
        Assert-CcodTrue $draft.State.DraftPrivate 'final stage private readback restores visibility before returning failure'
        Assert-CcodTrue (-not $draft.State.Promoted) 'final stage visibility drift never promotes'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-stage-final-tag-binding' 'Stage checks the remote tag commit after the final asset upload' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1StageFinalTag'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $state | Add-Member -NotePropertyName FinalTagDriftObserved -NotePropertyValue $false
        $expectedNames = [string[]]$assetFixture.Names
        $draft.Adapters.GetTagCommit = {
            param($Tag, [bool]$ActionsOnly)
            if ($state.Uploaded.Count -ge $expectedNames.Count) { $state.FinalTagDriftObserved = $true; return 'd' * 40 }
            return 'c' * 40
        }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED'
        Assert-CcodEqual $expectedNames.Count $state.Uploaded.Count 'all fixture assets were uploaded before the final tag change'
        Assert-CcodTrue $state.FinalTagDriftObserved 'Stage actually reaches and rejects the final tag-commit observation'
        Assert-CcodTrue $draft.State.DraftPrivate 'final tag mismatch keeps the draft private'
        Assert-CcodTrue (-not $draft.State.Promoted) 'final tag mismatch never promotes'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-default-adapter-property-order' 'Default GitHub adapter readbacks preserve the strict remote-view property order' {
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'))
    Assert-CcodTrue ($source.Contains('[pscustomobject][ordered]@{ Tag = $Tag; Id = $id; Draft = $true; AssetNames = @() }')) 'CreateDraft returns an ordered remote view object'
    Assert-CcodTrue ($source.Contains('[pscustomobject][ordered]@{ Tag = [string]$value.tagName; Id = $id; Draft = $value.isDraft; AssetNames = [string[]]$assetNames }')) 'ViewRelease returns an ordered remote view object'
}

Invoke-CcodTask6Test 'fix1-stage-private-recovery-validates-view-before-mutation' 'Stage private recovery validates the bound release identity before changing visibility' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1StageRecoveryView'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $state | Add-Member -NotePropertyName PrivateSetCalls -NotePropertyValue 0
        $state.DraftPrivate = $false
        $draft.Adapters.ViewRelease = {
            param($Tag)
            [pscustomobject][ordered]@{ Tag = $Tag; Id = [string]$state.DraftId; Draft = [bool]$state.DraftPrivate; AssetNames = @('unexpected.bin') }
        }.GetNewClosure()
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            if ($Draft) { $state.PrivateSetCalls++ }
            $state.DraftPrivate = $Draft
        }.GetNewClosure()
        & $module {param($Adapters) Restore-CcodGitHubDraftStagePrivateState -Adapters $Adapters -Tag 'v2.5.22' -Version '2.5.22' -DraftId '123' -ExpectedGitCommit ('c'*40)} $draft.Adapters
        Assert-CcodTrue $state.DraftPrivate 'same-ID control hides unexpected content before mutating only the release ID'
        $state.PrivateSetCalls = 0
        $state.DraftPrivate = $false
        $state.DraftId = '999'
        Assert-CcodThrows {
            &$module {
                param($Adapters)
                Restore-CcodGitHubDraftStagePrivateState -Adapters $Adapters -Tag 'v2.5.22' -Version '2.5.22' -DraftId '123' -ExpectedGitCommit ('c' * 40)
            } $draft.Adapters
        } 'CCOD_GITHUB_DRAFT_UPLOAD_PRIVATE_RECOVERY_FAILED'
        Assert-CcodEqual 0 $state.PrivateSetCalls 'stage recovery does not mutate an invalid release view'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-acceptance-module-import-path-safety' 'Acceptance validator import is guarded by plain-file and reparse ancestry validation' {
    $toolPath = Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1'
    $source = [IO.File]::ReadAllText($toolPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source.Contains('Assert-CcodGitHubDraftTrustedModulePath -Path $acceptanceModulePath -Directory $false')) 'acceptance import uses the complete trusted ancestry validator'
    $module = Import-CcodTask6ToolModule -Path $toolPath -Name 'CcodGitHubDraftTrustedModulePath'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-trusted-module-' + [guid]::NewGuid().ToString('N'))
    $link = Join-Path $root 'redirected'
    try {
        $modules = Join-Path $root 'plain\modules'
        [IO.Directory]::CreateDirectory($modules) | Out-Null
        $plain = Join-Path $modules 'validator.psm1'
        [IO.File]::WriteAllText($plain, '# inert module path fixture', [Text.UTF8Encoding]::new($false))
        $validated = &$module { param($Path) Assert-CcodGitHubDraftTrustedModulePath -Path $Path -Directory $false } $plain
        Assert-CcodEqual $plain $validated 'regular module with plain ancestry is accepted'
        New-Item -ItemType Junction -Path $link -Target (Join-Path $root 'plain') | Out-Null
        Assert-CcodThrows {
            &$module { param($Path) Assert-CcodGitHubDraftTrustedModulePath -Path $Path -Directory $false } (Join-Path $link 'modules\validator.psm1') | Out-Null
        } 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) }
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    }
}

Invoke-CcodTask6Test 'fix1-create-attempt-recovery' 'Stage records the create attempt before invoking remote draft creation' {
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source.Contains('$createAttempted = $true')) 'Stage records remote create before the adapter call'
    Assert-CcodTrue ($source.Contains('if ($created -or $createAttempted)')) 'Stage recovery covers a create adapter failure after remote mutation'
}

Invoke-CcodTask6Test 'fix1-create-attempt-tag-identity' 'Stage rejects ambiguous creation without changing visibility of an unowned release' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1CreateAttemptTagIdentity'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $state | Add-Member -NotePropertyName SetCalls -NotePropertyValue 0
        $draft.Adapters.CreateDraft = {
            param($Tag, $Title, $Notes)
            $state.Created = $true
            $state.DraftPrivate = $false
            throw 'create failed after remote mutation'
        }.GetNewClosure()
        $draft.Adapters.GetTagCommit = { param($Tag, [bool]$ActionsOnly) if ($state.Created) { 'd' * 40 } else { 'c' * 40 } }.GetNewClosure()
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            $state.SetCalls++
            $state.DraftPrivate = $Draft
        }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_CREATE_AMBIGUOUS'
        Assert-CcodTrue $state.Created 'fixture reaches creation before returning an ambiguous failure'
        Assert-CcodEqual 0 $state.SetCalls 'ambiguous creation never gains authority to mutate release visibility'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-stage-private-recovery-tag-identity' 'Stage private recovery contains a bound draft when its tag commit drifts' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1StageRecoveryTagIdentity'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $state | Add-Member -NotePropertyName UploadAttempted -NotePropertyValue $false
        $state | Add-Member -NotePropertyName SetCalls -NotePropertyValue 0
        $draft.Adapters.GetTagCommit = { param($Tag, [bool]$ActionsOnly) if ($state.UploadAttempted) { 'd' * 40 } else { 'c' * 40 } }.GetNewClosure()
        $draft.Adapters.UploadAsset = {
            param($Tag, $Name, $Path)
            $state.UploadAttempted = $true
            $state.DraftPrivate = $false
            throw 'upload failed after remote mutation'
        }.GetNewClosure()
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft, $ExpectedReleaseId)
            if ($ExpectedReleaseId -cne '123') { throw 'stage recovery ID was not bound' }
            $state.SetCalls++
            $state.DraftPrivate = $Draft
        }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED'
        Assert-CcodEqual 1 $state.SetCalls 'created-draft recovery hides the same release despite tag drift'
        Assert-CcodTrue $state.DraftPrivate 'a failed Stage is not left public'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-manual-proof-canonical-timestamp' 'Release promotion rejects noncanonical tray and remote proof timestamps' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1ManualProofTimestamp'
    try {
        $tray = [pscustomobject][ordered]@{ timestampUtc = '2030-02-03T04:05:06+00:00'; command = 'ShowAbout'; revision = [long]1; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }
        $remote = [pscustomobject][ordered]@{
            schemaVersion = 1; timestampUtc = '2030-02-03T04:05:06+00:00'; kind = 'remote-control-manual-proof'; operation = 'SecondDeviceControl'; deviceRole = 'SecondDevice'; challenge = 'run-1'; candidateVersion = '2.5.22'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [long]2; runtimeManifestSha256 = ('d' * 64); attestation = 'HumanReviewedStructuredAttestation'; connection = 'Connected'; control = 'Completed'; outcome = 'Completed'; code = 'CCOD_REMOTE_ACTION_COMPLETED'
        }
        $trayControl=$tray.PSObject.Copy();$trayControl.timestampUtc='2030-02-03T04:05:06.0000000Z'
        $remoteControl=$remote.PSObject.Copy();$remoteControl.timestampUtc='2030-02-03T04:05:06.0000000Z'
        Assert-CcodTrue (&$module {param($Proof)Test-CcodGitHubDraftManualProof -Proof $Proof -Index 0 -Version '2.5.22'} $trayControl) 'canonical tray proof is accepted before mutating only its timestamp'
        Assert-CcodTrue (&$module {param($Proof)Test-CcodGitHubDraftManualProof -Proof $Proof -Index 4 -Version '2.5.22'} $remoteControl) 'canonical remote proof is accepted before mutating only its timestamp'
        $trayValid = &$module { param($Proof) Test-CcodGitHubDraftManualProof -Proof $Proof -Index 0 -Version '2.5.22' } $tray
        $remoteValid = &$module { param($Proof) Test-CcodGitHubDraftManualProof -Proof $Proof -Index 4 -Version '2.5.22' } $remote
        Assert-CcodTrue (-not [bool]$trayValid -and -not [bool]$remoteValid) 'release manual proof validator rejects offset timestamps'
        $canonical=&$module {${function:Test-CcodGitHubDraftCanonicalUtc}}
        try {
            &$module {Set-Item -LiteralPath Function:script:Test-CcodGitHubDraftCanonicalUtc -Value {param($Value)return $true}}
            Assert-CcodTrue (&$module {param($Proof)Test-CcodGitHubDraftManualProof -Proof $Proof -Index 0 -Version '2.5.22'} $tray) 'removing only the timestamp guard makes the otherwise-valid tray negative pass'
            Assert-CcodTrue (&$module {param($Proof)Test-CcodGitHubDraftManualProof -Proof $Proof -Index 4 -Version '2.5.22'} $remote) 'removing only the timestamp guard makes the otherwise-valid remote negative pass'
        } finally {&$module {param($Original)Set-Item -LiteralPath Function:script:Test-CcodGitHubDraftCanonicalUtc -Value $Original} $canonical}
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

Invoke-CcodTask6Test 'review2-stage-held-upload' 'Stage uploads only originally validated frozen bytes through readback' {
    $module=Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodStageHeldUpload'
    $fixture=$null
    try {
        $fixture=New-CcodTask5ExactAssetFixture
        $originals=@{};foreach($name in $fixture.Names){$originals[$name]=[IO.File]::ReadAllBytes((Join-Path $fixture.Root $name))}
        foreach($mode in @('Clean','AtUpload','AtReadback')) {
            $evidence=Join-Path $fixture.Outside $mode;[IO.Directory]::CreateDirectory($evidence)|Out-Null
            Write-CcodTask5Json -Path (Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json') -Value ([ordered]@{schemaVersion=1;valid=$true;version='2.5.22';gitCommit=$fixture.GitCommit;repositoryRoot=[IO.Path]::GetFullPath($repositoryRoot)})
            $draft=New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root;$state=$draft.State
            $probe=[pscustomobject]@{Attempts=0;Blocked=0;Remote=@{};Frozen=$null;ReadCount=0}
            $draft.Adapters.UploadAsset={
                param($Tag,$Name,$Path)
                $probe.Frozen=Split-Path -Parent $Path
                if($mode-ceq'AtUpload'-and$Name-ceq$fixture.Names[0]){
                    $probe.Attempts++
                    try{[IO.File]::WriteAllText($Path,'replacement-before-native-upload')}catch [IO.IOException]{$probe.Blocked++}
                }
                $probe.Remote[$Name]=[IO.File]::ReadAllBytes($Path);$state.Uploaded.Add($Name)
            }.GetNewClosure()
            $draft.Adapters.DownloadAsset={
                param($Tag,$Name,$Destination)
                $probe.ReadCount++
                if($mode-ceq'AtReadback'-and$probe.ReadCount-eq1){
                    $probe.Attempts++
                    try{[IO.File]::WriteAllText((Join-Path $probe.Frozen $Name),'replacement-before-readback');$probe.Remote[$Name]=[IO.File]::ReadAllBytes((Join-Path $probe.Frozen $Name))}catch [IO.IOException]{$probe.Blocked++}
                }
                [IO.File]::WriteAllBytes($Destination,[byte[]]$probe.Remote[$Name])
            }.GetNewClosure()
            $result=Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters
            Assert-CcodTrue $result.Draft 'the isolated adapter keeps publication private'
            Assert-CcodEqual $fixture.Names.Count $probe.ReadCount 'every uploaded byte set is read from the simulated remote, not the original directory'
            foreach($name in $fixture.Names){Assert-CcodEqual ([Convert]::ToBase64String($originals[$name])) ([Convert]::ToBase64String($probe.Remote[$name])) 'uploaded bytes retain the independently captured original identity'}
            if($mode-cne'Clean'){Assert-CcodEqual 1 $probe.Attempts 'one mutation reaches consumption';Assert-CcodEqual 1 $probe.Blocked 'held authority blocks the attempted changed bytes'}
            Assert-CcodTrue (-not[IO.Directory]::Exists($probe.Frozen)) 'owned frozen directory is removed after all held files are released'
        }
    } finally {Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue;if($null-ne$fixture){Remove-CcodTask5ExactAssetFixture $fixture}}
}

Invoke-CcodTask6Test 'review2-native-commit-shape' 'native tag commits remain one exact lowercase scalar without repairing output' {
    $module=Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodNativeCommitShape'
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-native-commit-'+[guid]::NewGuid().ToString('N'))
    $fakeGh=Join-Path $root 'gh.cmd';$acceptedInvalid=[Collections.Generic.List[string]]::new()
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        & $module {
            param($Path)
            $script:CcodCommitGh=$Path
            Set-Item Function:script:Assert-CcodGitHubDraftAuthenticatedContext -Value {param($Tag)}
            Set-Item Function:script:Assert-CcodGitHubDraftActionsContext -Value {param($Tag)}
            Set-Alias -Name gh -Value $Path -Scope Script
        } $fakeGh
        foreach($mode in @('Valid','Split','Whitespace','Uppercase','BlankBefore','BlankAfter','Duplicate','Empty','ExitFailure')) {
            $lines=switch($mode) {
                'Valid' {@('echo('+('c'*40))}
                'Split' {@(('echo('+('c'*20)),('echo('+('c'*20)))}
                'Whitespace' {@('echo( '+('c'*40)+' ')}
                'Uppercase' {@('echo('+('C'*40))}
                'BlankBefore' {@('echo(',('echo('+('c'*40)))}
                'BlankAfter' {@(('echo('+('c'*40)),'echo(')}
                'Duplicate' {@(('echo('+('c'*40)),('echo('+('c'*40)))}
                'Empty' {@()}
                'ExitFailure' {@('echo('+('c'*40))}
            }
            $exitValue=if($mode-ceq'ExitFailure'){3}else{0}
            [IO.File]::WriteAllText($fakeGh,(@('@echo off')+@($lines)+@('exit /b '+$exitValue)-join"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
            foreach($actionsOnly in @($false,$true)) {
                $failure=$null;$value=$null
                try{$value=&$module {param($Actions) Get-CcodGitHubDraftTagCommit -Tag 'v2.5.22' -ActionsOnly $Actions} $actionsOnly}catch{$failure=$_.FullyQualifiedErrorId}
                if($mode-ceq'Valid') {
                    Assert-CcodEqual $null $failure 'ordinary native newline termination is accepted'
                    Assert-CcodEqual ('c'*40) $value 'one canonical native SHA is returned unchanged'
                } elseif($null-eq$failure){$acceptedInvalid.Add($mode+':'+$actionsOnly)}
                else{Assert-CcodTrue ($failure-like'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED*') 'invalid native commit uses the specific failure'}
            }
        }
        Assert-CcodEqual '' ($acceptedInvalid-join',') 'no multi-line or noncanonical native SHA is repaired into acceptance'
    } finally {Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue;if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}}
}

Invoke-CcodTask6Test 'review2-final-commit-shape' 'Verify never repairs a malformed tag SHA before or after receipt publication' {
    $module=Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodFinalCommitShape'
    $fixture=$null
    try {
        $fixture=New-CcodTask5ExactAssetFixture
        foreach($mode in @('Valid','Whitespace','Uppercase','PostPublication')) {
            $evidence=Join-Path $fixture.Outside $mode;[IO.Directory]::CreateDirectory($evidence)|Out-Null
            Write-CcodTask5Json -Path (Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json') -Value ([ordered]@{schemaVersion=1;valid=$true;version='2.5.22';gitCommit=$fixture.GitCommit;repositoryRoot=[IO.Path]::GetFullPath($repositoryRoot)})
            $path=&$module {param($Root) Get-CcodGitHubDraftVerificationPath -EvidenceDirectory $Root -Version '2.5.22'} $evidence
            $draft=New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root;$state=$draft.State
            $state.Uploaded.AddRange([string[]]$fixture.Names)
            $probe=[pscustomobject]@{Downloads=0;Injected=0;PublicationSeen=$false}
            $draft.Adapters.DownloadAsset={param($Tag,$Name,$Destination)[IO.File]::Copy((Join-Path $fixture.Root $Name),$Destination,$false);$probe.Downloads++}.GetNewClosure()
            $draft.Adapters.GetTagCommit={
                param($Tag,$ActionsOnly)
                $published=[IO.File]::Exists($path)
                if($published){$probe.PublicationSeen=$true}
                if($mode-cne'Valid'-and$probe.Downloads-eq$fixture.Names.Count-and($mode-cne'PostPublication'-or$published)) {
                    $probe.Injected++
                    if($mode-ceq'Uppercase'){return ('C'*40)}
                    return (' '+$fixture.GitCommit)
                }
                return $fixture.GitCommit
            }.GetNewClosure()
            if($mode-ceq'Valid') {
                $result=Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters
                Assert-CcodTrue $result.Verified 'canonical final observations and real publication are a passing control'
                Assert-CcodEqual $path $result.VerificationPath 'control uses the actual production verification target'
                Assert-CcodTrue $probe.PublicationSeen 'passing control covers the readback callback after publication'
            } else {
                Assert-CcodThrows {Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters|Out-Null} 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID'
                Assert-CcodTrue ($probe.Injected-gt0) 'malformed final SHA reaches the target callback'
                Assert-CcodTrue (-not[IO.File]::Exists($path)) 'invalid final identity leaves no success-shaped verification'
                if($mode-ceq'PostPublication'){Assert-CcodTrue $probe.PublicationSeen 'late negative crosses actual publication before rollback'}
            }
            Assert-CcodEqual $fixture.Names.Count $probe.Downloads 'all exact assets are downloaded before the target seam'
        }
    } finally {Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue;if($null-ne$fixture){Remove-CcodTask5ExactAssetFixture $fixture}}
}

Invoke-CcodTask6Test 'review2-commit-binding-shape' 'tag binding rejects noncanonical adapter SHA before comparison' {
    $module=Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodCommitBindingShape'
    try {
        $state=[pscustomobject]@{Raw=('c'*40)}
        $adapters=@{GetTagCommit={param($Tag,$ActionsOnly) return ,$state.Raw}.GetNewClosure()}
        & $module {param($Adapters) Assert-CcodGitHubDraftTagCommit -Tag 'v2.5.22' -ExpectedCommit ('c'*40) -Adapters $Adapters -ActionsOnly $false} $adapters
        $invalid=[Collections.Generic.List[object]]::new()
        $invalid.Add([object]@('c'*40));$invalid.Add(' '+('c'*40));$invalid.Add(('c'*40)+"`n");$invalid.Add('C'*40);$invalid.Add([pscustomobject]@{value=('c'*40)})
        $accepted=0
        foreach($raw in $invalid) {
            $state.Raw=$raw;$failure=$null
            try{&$module {param($Adapters) Assert-CcodGitHubDraftTagCommit -Tag 'v2.5.22' -ExpectedCommit ('c'*40) -Adapters $Adapters -ActionsOnly $false} $adapters}catch{$failure=$_.FullyQualifiedErrorId}
            if($null-eq$failure){$accepted++}else{Assert-CcodTrue ($failure-like'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED*') 'malformed observed SHA fails before equality comparison'}
        }
        Assert-CcodEqual 0 $accepted 'caller does not repair whitespace or case after a native or private adapter'
    } finally {Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue}
}

Invoke-CcodTask6Test 'review-native-private-id' 'native private recovery addresses a strict numeric release ID rather than a mutable tag' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodNativePrivateId'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-native-private-id-' + [guid]::NewGuid().ToString('N'))
    $fakeGh = Join-Path $root 'gh.cmd'
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText($fakeGh,"@echo off`r`necho %*>>`"%~dp0calls.txt`"`r`necho native-fixture-output`r`nexit /b 0`r`n",[Text.UTF8Encoding]::new($false))
        & $module {
            param($Path)
            $script:CcodPrivateFakeGh=$Path
            $script:CcodPrivateCalls=0
            Set-Item Function:script:Assert-CcodGitHubDraftAuthenticatedContext -Value {param($Tag)}
            Set-Item Function:script:gh -Value { $script:CcodPrivateCalls++; & $script:CcodPrivateFakeGh @args; $script:LASTEXITCODE=$LASTEXITCODE }
        } $fakeGh
        $output=@(& $module { $adapters=Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.SetReleaseDraftState 'v2.5.22' $true '123' })
        Assert-CcodEqual 0 $output.Count 'native mutation output is not exposed as a success value'
        $line=[IO.File]::ReadAllText((Join-Path $root 'calls.txt')).Trim()
        Assert-CcodEqual 'api repos/naipi11/CodexRemote-fix/releases/123 --method PATCH --field draft=true --silent' $line 'the visibility write is pinned to the authenticated numeric ID'
        foreach($bad in @($null,'',123,@('123'),'0123','123/../999',"123`n")){
            $before=& $module {$script:CcodPrivateCalls}
            Assert-CcodThrows { & $module {param($Id) $adapters=Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.SetReleaseDraftState 'v2.5.22' $true $Id} $bad } 'CCOD_GITHUB_DRAFT_PROMOTE_FAILED'
            Assert-CcodEqual $before (& $module {$script:CcodPrivateCalls}) 'invalid bound ID is rejected before any native call'
        }
        & $module {$adapters=Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.SetReleaseDraftState 'v2.5.22' $false '123'}
        $lines=[IO.File]::ReadAllLines((Join-Path $root 'calls.txt'))
        Assert-CcodEqual 'api repos/naipi11/CodexRemote-fix/releases/123 --method PATCH --field draft=false --silent' $lines[-1].Trim() 'publication uses the same immutable ID and the explicit Boolean requested by its gated caller'
        $before=& $module {$script:CcodPrivateCalls}
        Assert-CcodThrows { & $module {$adapters=Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.SetReleaseDraftState 'v2.5.22' $false} } 'CCOD_GITHUB_DRAFT_PROMOTE_FAILED'
        Assert-CcodEqual $before (& $module {$script:CcodPrivateCalls}) 'unbound visibility changes are rejected rather than falling back to tag addressing'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
    }
}

Invoke-CcodTask6Test 'review-bound-private-recovery' 'bound release recovery restores privacy despite asset or tag drift' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodBoundPrivateRecovery'
    $fixture = $null
    try {
        & $module { Import-CcodDraftReleaseAssetContract }
        $fixture = New-CcodTask5ExactAssetFixture
        foreach ($mode in @('Promote','Stage')) {
            foreach ($change in @('None','Missing','Extra','TagDrift')) {
                $state = [pscustomobject]@{ Private=$false; Calls=0; TargetId=$null; Names=[string[]]$fixture.Names; Commit=[string]$fixture.GitCommit }
                if($change -ceq 'Missing'){$state.Names=@($fixture.Names | Select-Object -Skip 1)}
                if($change -ceq 'Extra'){$state.Names=@($fixture.Names)+@('unexpected.txt')}
                if($change -ceq 'TagDrift'){$state.Commit='d'*40}
                $adapters = @{
                    ViewRelease = { param($Tag) [pscustomobject][ordered]@{Tag=$Tag;Id='123';Draft=$state.Private;AssetNames=@($state.Names)} }.GetNewClosure()
                    GetTagCommit = { param($Tag,$ActionsOnly) $state.Commit }.GetNewClosure()
                    SetReleaseDraftState = { param($Tag,[bool]$Draft,$ExpectedReleaseId) $state.Calls++;$state.TargetId=$ExpectedReleaseId;$state.Private=$Draft }.GetNewClosure()
                }
                [Console]::WriteLine('CCOD_BOUND_RECOVERY mode='+$mode+' change='+$change)
                & $module {
                    param($Adapters,$Mode,$Commit)
                    if($Mode -ceq 'Promote'){
                        Restore-CcodGitHubDraftPrivateState -Adapters $Adapters -Tag 'v2.5.22' -Version '2.5.22' -Verification ([pscustomobject]@{draftId='123'}) -Acceptance ([pscustomobject]@{draft=[pscustomobject]@{id='123'}}) -ExpectedGitCommit $Commit
                    }else{
                        Restore-CcodGitHubDraftStagePrivateState -Adapters $Adapters -Tag 'v2.5.22' -Version '2.5.22' -DraftId '123' -ExpectedGitCommit $Commit
                    }
                } $adapters $mode $fixture.GitCommit
                Assert-CcodTrue $state.Private 'failed content must not prevent restoring the authenticated release to private'
                Assert-CcodEqual 1 $state.Calls 'one private visibility mutation is requested'
                if($change -cne 'None'){Assert-CcodEqual '123' $state.TargetId 'recovery mutation carries the already-bound release ID'}
                Assert-CcodEqual ([string]$state.Commit) ([string](& $adapters.GetTagCommit 'v2.5.22' $false)) 'recovery does not repair or silently normalize tag content'
            }
        }
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if($null -ne $fixture){Remove-CcodTask5ExactAssetFixture $fixture}
    }
}

Invoke-CcodTask6Test 'review-bound-recovery-denials' 'private recovery rejects identity ambiguity and never targets a retargeted release' {
    $module=Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodRecoveryDenials'
    try {
        foreach($case in @('None','AlreadyPrivate','BeforeId','BeforeTag','BeforeDraftType','ReceiptArray','ReceiptMismatch','IdZero','IdLF','AfterId','AfterPublic','WriteThrows','TagRace')){
            $state=[pscustomobject]@{ Reads=0; Writes=0; Private=$false; OtherPrivate=$false; BeforeId='123'; BeforeTag='v2.5.22'; BoundId=$null }
            $verification=[pscustomobject]@{draftId='123'}
            $acceptance=[pscustomobject]@{draft=[pscustomobject]@{id='123'}}
            if($case -ceq 'AlreadyPrivate'){$state.Private=$true}
            if($case -ceq 'BeforeId'){$state.BeforeId='999'}
            if($case -ceq 'BeforeTag'){$state.BeforeTag='v2.5.21'}
            if($case -ceq 'ReceiptArray'){$verification.draftId=@('123')}
            if($case -ceq 'ReceiptMismatch'){$acceptance.draft.id='999'}
            if($case -ceq 'IdZero'){$verification.draftId='0';$acceptance.draft.id='0';$state.BeforeId='0'}
            if($case -ceq 'IdLF'){$verification.draftId="123`n";$acceptance.draft.id="123`n";$state.BeforeId="123`n"}
            $adapters=@{
                ViewRelease={param($Tag)
                    $state.Reads++
                    $id=$state.BeforeId;$private=$state.Private
                    if($state.Reads -gt 1 -and $case -in @('AfterId','TagRace')){$id='999'}
                    if($case -ceq 'BeforeDraftType'){$private='false'}
                    if($state.Reads -gt 1 -and $case -ceq 'AfterPublic'){$private=$false}
                    [pscustomobject][ordered]@{Tag=$state.BeforeTag;Id=$id;Draft=$private;AssetNames=@('untrusted-content.bin')}
                }.GetNewClosure()
                SetReleaseDraftState={param($Tag,[bool]$Draft,$ExpectedReleaseId)
                    $state.Writes++;$state.BoundId=$ExpectedReleaseId
                    if($case -ceq 'WriteThrows'){throw 'native write failure'}
                    $target=if($null -ne $ExpectedReleaseId){$ExpectedReleaseId}elseif($case -ceq 'TagRace'){'999'}else{'123'}
                    if($target -ceq '123'){$state.Private=$Draft}else{$state.OtherPrivate=$Draft}
                }.GetNewClosure()
                GetTagCommit={throw 'content validation must not gate containment'}
            }
            $invoke={&$module {param($A,$V,$E) Restore-CcodGitHubDraftPrivateState -Adapters $A -Tag 'v2.5.22' -Version '2.5.22' -Verification $V -Acceptance $E -ExpectedGitCommit ('c'*40)} $adapters $verification $acceptance}.GetNewClosure()
            if($case -in @('None','AlreadyPrivate')){
                & $invoke
                Assert-CcodTrue $state.Private 'successful recovery is followed by a private readback'
                Assert-CcodEqual 2 $state.Reads 'successful recovery reads the bound release before and after'
            }else{Assert-CcodThrows {& $invoke} 'CCOD_GITHUB_DRAFT_PROMOTE_ROLLBACK_FAILED'}
            $expectedWrites=if($case -in @('None','AfterId','AfterPublic','WriteThrows','TagRace')){1}else{0}
            Assert-CcodEqual $expectedWrites $state.Writes "$case does not mutate before identity authorization"
            Assert-CcodTrue (-not $state.OtherPrivate) 'retargeting cannot cause a different release to be hidden'
            if($state.Writes){Assert-CcodEqual '123' $state.BoundId 'every recovery write retains the original ID'}
        }
    } finally {Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue}
}

Invoke-CcodTask6Test 'fix1-private-recovery-identity-before-mutation' 'Promote recovery validates release identity before changing visibility' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1RecoveryIdentity'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $state | Add-Member -NotePropertyName SetCalls -NotePropertyValue 0
        $expectedNames = [string[]]$assetFixture.Names
        $draft.Adapters.ViewRelease = {
            param($Tag)
            [pscustomobject][ordered]@{ Tag = $Tag; Id = '999'; Draft = $false; AssetNames = $expectedNames }
        }.GetNewClosure()
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            $state.SetCalls++
        }.GetNewClosure()
        $verification = [pscustomobject][ordered]@{ draftId = '123' }
        $acceptance = [pscustomobject][ordered]@{ draft = [pscustomobject][ordered]@{ id = '123' } }
        Assert-CcodThrows {
            &$module {
                param($Adapters,$Verification,$Acceptance)
                Restore-CcodGitHubDraftPrivateState -Adapters $Adapters -Tag 'v2.5.22' -Version '2.5.22' -Verification $Verification -Acceptance $Acceptance -ExpectedGitCommit ('c' * 40)
            } $draft.Adapters $verification $acceptance
        } 'CCOD_GITHUB_DRAFT_PROMOTE_ROLLBACK_FAILED'
        Assert-CcodEqual 0 $state.SetCalls 'private recovery does not mutate an unverified release identity'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-post-promote-recovery-uses-identity-first-helper' 'Post-promotion readback recovery delegates identity validation before visibility mutation' {
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'))
    $start = $source.LastIndexOf('$postReadRoot = $null')
    $end = $source.Length
    Assert-CcodTrue ($start -ge 0 -and $end -gt $start) 'post-promotion readback recovery block is present'
    $block = $source.Substring($start, $end - $start)
    Assert-CcodTrue ($block.Contains('Restore-CcodGitHubDraftPrivateState -Adapters $adapters')) 'post-promotion recovery uses the identity-first helper'
    Assert-CcodTrue (-not $block.Contains('& $adapters.SetReleaseDraftState $Tag $true')) 'post-promotion recovery does not mutate visibility before identity validation'
}

Invoke-CcodTask6Test 'review-native-json-field-order' 'default GitHub adapters accept reordered native JSON without relaxing identity types' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodNativeJsonFieldOrder'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-native-json-order-' + [guid]::NewGuid().ToString('N'))
    $fakeGh = Join-Path $root 'gh.cmd'
    $response = Join-Path $root 'response.json'
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText($fakeGh, "@echo off`r`nif `"%1`"==`"release`" if `"%2`"==`"create`" exit /b 0`r`nif `"%1`"==`"release`" if `"%2`"==`"view`" (`r`n  type `"%~dp0response.json`"`r`n  exit /b 0`r`n)`r`nexit /b 87`r`n", [Text.UTF8Encoding]::new($false))
        & $module {
            param($FakeGh)
            $script:CcodNativeJsonGh = $FakeGh
            $script:CcodNativeJsonCalls = 0
            Set-Item Function:script:Assert-CcodGitHubDraftAuthenticatedContext -Value { param($Tag) }
            Set-Item Function:script:Assert-CcodGitHubDraftActionsContext -Value { param($Tag) }
            Set-Item Function:script:gh -Value {
                if (($args -join '|') -cnotmatch '\|--repo\|naipi11/CodexRemote-fix\|') { throw 'native fixture received an unbound repository' }
                $script:CcodNativeJsonCalls++
                & $script:CcodNativeJsonGh @args
                $script:LASTEXITCODE = $LASTEXITCODE
            }
        } $fakeGh
        $expectedCalls = 0
        foreach ($mode in @('CreateDraft','ViewRelease')) {
            $value = [pscustomobject][ordered]@{ databaseId = [long]2147483648; tagName = 'v2.5.22'; isDraft = $true }
            $orders = @('databaseId,tagName,isDraft','databaseId,isDraft,tagName','isDraft,tagName,databaseId')
            $errorId = 'CCOD_GITHUB_DRAFT_CREATE_FAILED'
            $callsPerInvocation = 2
            if ($mode -ceq 'ViewRelease') {
                $value | Add-Member -NotePropertyName assets -NotePropertyValue @([pscustomobject]@{name='first.zip'},[pscustomobject]@{name='second.exe'})
                $orders = @('tagName,isDraft,databaseId,assets','assets,databaseId,isDraft,tagName','isDraft,assets,tagName,databaseId')
                $errorId = 'CCOD_GITHUB_DRAFT_NOT_STAGED'
                $callsPerInvocation = 1
            }
            $invoke = {
                & $module { param($Mode) $adapters=Get-CcodGitHubDraftReleaseDefaultAdapters; if($Mode -ceq 'CreateDraft'){& $adapters.CreateDraft 'v2.5.22' 'fixture title' 'fixture notes'}else{& $adapters.ViewRelease 'v2.5.22'} } $mode
            }.GetNewClosure()
            foreach ($order in $orders) {
                $reordered = [ordered]@{}
                foreach ($name in $order.Split(',')) { $reordered[$name] = $value.$name }
                [IO.File]::WriteAllText($response,($reordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
                [Console]::WriteLine('CCOD_NATIVE_JSON_ORDER mode=' + $mode + ' fields=' + $order)
                $result = & $invoke
                $expectedCalls += $callsPerInvocation
                Assert-CcodEqual '2147483648' $result.Id "$mode accepts exact fields in native order $order"
                Assert-CcodTrue ($result.Draft -is [bool] -and $result.Draft) 'draft state remains a strict Boolean'
                Assert-CcodEqual 'v2.5.22' $result.Tag 'tag identity remains exact'
                if ($mode -ceq 'ViewRelease') { Assert-CcodEqual 'first.zip,second.exe' ($result.AssetNames -join ',') 'asset array is preserved' }
            }
            foreach ($bad in @('Missing','Extra','Case','IdString','IdBoolean','IdFraction','IdZero','TagArray','TagMismatch','DraftString','Null')) {
                $mutated = $value.PSObject.Copy()
                switch ($bad) {
                    'Missing' { $mutated.PSObject.Properties.Remove('databaseId') }
                    'Extra' { $mutated | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }
                    'IdString' { $mutated.databaseId = '2147483648' }
                    'IdBoolean' { $mutated.databaseId = $true }
                    'IdFraction' { $mutated.databaseId = [double]123.5 }
                    'IdZero' { $mutated.databaseId = 0 }
                    'TagArray' { $mutated.tagName = @('v2.5.22') }
                    'TagMismatch' { $mutated.tagName = 'v2.5.21' }
                    'DraftString' { $mutated.isDraft = 'true' }
                }
                $json = $mutated | ConvertTo-Json -Depth 8 -Compress
                if ($bad -ceq 'Case') { $json = $json.Replace('"databaseId":','"DatabaseId":') }
                if ($bad -ceq 'Null') { $json = 'null' }
                [IO.File]::WriteAllText($response,$json,[Text.UTF8Encoding]::new($false))
                Assert-CcodThrows { & $invoke | Out-Null } $errorId
                $expectedCalls += $callsPerInvocation
            }
        }
        Assert-CcodEqual $expectedCalls (& $module {$script:CcodNativeJsonCalls}) 'every adapter invocation used only the local native fixture'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) }
    }
}

Invoke-CcodTask6Test 'fix2-view-database-id' 'default GitHub ViewRelease rejects coerced database IDs using only a local gh stub' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodViewDatabaseId'
    try {
        &$module {
            $script:CcodViewGhCalls = 0
            Set-Item Function:script:Assert-CcodGitHubDraftAuthenticatedContext -Value { param($Tag) }
            Set-Item Function:script:gh -Value {
                $script:LASTEXITCODE = 0
                $script:CcodViewGhCalls++
                return $script:CcodViewJson
            }
        }
        foreach ($case in @(
            [pscustomobject]@{ Json = '123'; Valid = $true },
            [pscustomobject]@{ Json = '2147483648'; Valid = $true },
            [pscustomobject]@{ Json = '[123]'; Valid = $false },
            [pscustomobject]@{ Json = '"123"'; Valid = $false },
            [pscustomobject]@{ Json = 'true'; Valid = $false },
            [pscustomobject]@{ Json = '123.5'; Valid = $false },
            [pscustomobject]@{ Json = 'null'; Valid = $false },
            [pscustomobject]@{ Json = '0'; Valid = $false }
        )) {
            &$module { param($Value) $script:CcodViewJson = '{"tagName":"v2.5.22","isDraft":true,"databaseId":' + $Value + ',"assets":[]}' } $case.Json
            $invoke = { &$module { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.ViewRelease 'v2.5.22' } }
            if ($case.Valid) {
                $view = & $invoke
                Assert-CcodEqual $case.Json $view.Id 'canonical JSON Int32/Int64 database ID is accepted'
            } else { Assert-CcodThrows { & $invoke | Out-Null } 'CCOD_GITHUB_DRAFT_NOT_STAGED' }
        }
        Assert-CcodEqual 8 (&$module { $script:CcodViewGhCalls }) 'every view is served by the module-local gh stub'
    } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
}

Invoke-CcodTask6Test 'fix2-create-tag-type' 'Stage rejects singleton array tags from creation before any asset upload' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodCreateTagType'
    $fixture = $null
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-create-tag-type-' + [guid]::NewGuid().ToString('N'))
    try {
        $fixture = New-CcodTask5ExactAssetFixture
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-CcodTask5Json (Join-Path $root 'CodexRemote-fix-2.5.22-clean-preflight.json') ([ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = $fixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) })
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
        $draft.Adapters.CreateDraft = { param($Tag,$Title,$Notes) [pscustomobject][ordered]@{ Tag = @($Tag); Id = '123'; Draft = $true; AssetNames = @() } }
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $root -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_CREATE_AMBIGUOUS'
        Assert-CcodEqual 0 $draft.State.Uploaded.Count 'malformed creation identity cannot authorize upload'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
        if ($null -ne $fixture) { Remove-CcodTask5ExactAssetFixture $fixture }
    }
}

Invoke-CcodTask6Test 'fix1-post-promote-readback' 'Promote re-downloads and re-hashes public assets after changing draft visibility' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1PostPromote'
    $assetFixture = $null
    $promotion = $null
    $remoteRoot = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $expected = [string[]]$assetFixture.Names
        $remoteRoot = Join-Path $assetFixture.Outside 'remote-assets'
        [IO.Directory]::CreateDirectory($remoteRoot) | Out-Null
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $draft.Adapters.UploadAsset = {
            param($Tag, $Name, $Path)
            [IO.File]::Copy($Path, (Join-Path $remoteRoot $Name), $true)
            $state.Uploaded.Add($Name)
        }.GetNewClosure()
        $draft.Adapters.DownloadAsset = {
            param($Tag, $Name, $Destination)
            [IO.File]::Copy((Join-Path $remoteRoot $Name), $Destination, $true)
        }.GetNewClosure()
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $state | Add-Member -NotePropertyName PublicAttempts -NotePropertyValue 0
        $state | Add-Member -NotePropertyName RecoveryWrites -NotePropertyValue 0
        foreach ($change in @('Bytes','Missing','Extra')) {
            foreach($name in $expected){[IO.File]::Copy((Join-Path $assetFixture.Root $name),(Join-Path $remoteRoot $name),$true)}
            $state.Uploaded.Clear();$state.Uploaded.AddRange($expected)
            $state.DraftPrivate=$true;$state.Promoted=$false
            $beforePublic=$state.PublicAttempts;$beforeRecovery=$state.RecoveryWrites
            $draft.Adapters.SetReleaseDraftState = {
                param($Tag, [bool]$Draft, $ExpectedReleaseId)
                if($ExpectedReleaseId -cne '123'){throw 'all visibility writes must carry the bound release ID'}
                $state.DraftPrivate = $Draft
                $state.Promoted = -not $Draft
                if (-not $Draft) {
                    $state.PublicAttempts++
                    if($change -ceq 'Bytes'){[IO.File]::WriteAllText((Join-Path $remoteRoot $expected[0]),'post-promotion-mutated',[Text.UTF8Encoding]::new($false))}
                    if($change -ceq 'Missing'){[IO.File]::Delete((Join-Path $remoteRoot $expected[0]));[void]$state.Uploaded.Remove($expected[0])}
                    if($change -ceq 'Extra'){$state.Uploaded.Add('unexpected.txt');[IO.File]::WriteAllText((Join-Path $remoteRoot 'unexpected.txt'),'unexpected',[Text.UTF8Encoding]::new($false))}
                }else{
                    if($ExpectedReleaseId -cne '123'){throw 'post-promotion recovery ID was not bound'}
                    $state.RecoveryWrites++
                }
            }.GetNewClosure()
            Assert-CcodThrows {
                Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
            } 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED'
            Assert-CcodEqual ($beforePublic+1) $state.PublicAttempts "$change occurs only after actual fixture publication"
            Assert-CcodEqual ($beforeRecovery+1) $state.RecoveryWrites "$change triggers bound-ID recovery"
            Assert-CcodTrue (-not $state.Promoted -and $state.DraftPrivate) 'post-promotion content failures restore the same draft to private before failing'
        }
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-post-promote-tag-identity' 'Promote rechecks the immutable tag commit after the final public asset readback' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1PostPromoteTagIdentity'
    $assetFixture = $null
    $promotion = $null
    $remoteRoot = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $expected = [string[]]$assetFixture.Names
        $remoteRoot = Join-Path $assetFixture.Outside 'remote-assets'
        [IO.Directory]::CreateDirectory($remoteRoot) | Out-Null
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $state | Add-Member -NotePropertyName PostRootReadyAtPublic -NotePropertyValue $false
        $mutation = [pscustomobject]@{ DownloadCount = 0; TagSwapped = $false }
        $draft.Adapters.UploadAsset = {
            param($Tag, $Name, $Path)
            [IO.File]::Copy($Path, (Join-Path $remoteRoot $Name), $true)
            $state.Uploaded.Add($Name)
        }.GetNewClosure()
        $draft.Adapters.GetTagCommit = {
            param($Tag, [bool]$ActionsOnly)
            if ($mutation.TagSwapped) { 'd' * 40 } else { 'c' * 40 }
        }.GetNewClosure()
        $draft.Adapters.DownloadAsset = {
            param($Tag, $Name, $Destination)
            [IO.File]::Copy((Join-Path $remoteRoot $Name), $Destination, $true)
            $mutation.DownloadCount++
            if ($mutation.DownloadCount -eq 44) { $mutation.TagSwapped = $true }
        }.GetNewClosure()
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            if (-not $Draft) {
                $state.PostRootReadyAtPublic = @([IO.Directory]::GetDirectories([IO.Path]::GetTempPath(), 'ccod-draft-post-promote-*')).Count -gt 0
            }
            $state.DraftPrivate = $Draft
            $state.Promoted = -not $Draft
        }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_TAG_COMMIT_MISMATCH'
        Assert-CcodTrue $state.PostRootReadyAtPublic 'post-readback root must be prepared before public visibility mutation'
        Assert-CcodTrue ($mutation.TagSwapped -and $mutation.DownloadCount -eq 44) 'tag identity changes only after the final public asset readback'
        Assert-CcodTrue (-not $state.Promoted -and $state.DraftPrivate) 'same release ID is restored private while the original tag failure remains reported'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-restore-revalidates-tag-commit' 'Private recovery restores the bound release despite a changed tag commit' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1RestoreTagCommit'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $names = [string[]]$assetFixture.Names
        $state = [pscustomobject]@{ Private = $false; TargetId = $null }
        $adapters = @{
            ViewRelease = { param($Tag) [pscustomobject][ordered]@{ Tag = $Tag; Id = '123'; Draft = $state.Private; AssetNames = $names } }.GetNewClosure()
            SetReleaseDraftState = { param($Tag, [bool]$Draft, $ExpectedReleaseId) $state.Private = $Draft; $state.TargetId = $ExpectedReleaseId }.GetNewClosure()
            GetTagCommit = { param($Tag, [bool]$ActionsOnly) 'd' * 40 }.GetNewClosure()
        }
        $verification = [pscustomobject]@{ draftId = '123' }
        $acceptance = [pscustomobject]@{ draft = [pscustomobject]@{ id = '123' } }
        &$module { param($Adapters,$Verification,$Acceptance) Restore-CcodGitHubDraftPrivateState -Adapters $Adapters -Tag 'v2.5.22' -Version '2.5.22' -Verification $Verification -Acceptance $Acceptance -ExpectedGitCommit ('c' * 40) } $adapters $verification $acceptance
        Assert-CcodTrue $state.Private 'content drift does not prevent privacy containment for the authenticated ID'
        Assert-CcodEqual '123' $state.TargetId 'recovery does not select a release using its changed tag commit'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-promote-final-evidence-hold' 'Promote rejects a valid acceptance replacement after final evidence was initially held' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1FinalEvidenceHold'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $verification = Join-Path $promotion.Root 'verification'
        $acceptance = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        [IO.Directory]::CreateDirectory($verification) | Out-Null
        [IO.Directory]::CreateDirectory($acceptance) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $draft.Adapters.UploadAsset = { param($Tag,$Name,$Path); $state.Uploaded.Add($Name); [IO.File]::Copy($Path,(Join-Path $promotion.Root ('remote-' + $Name)),$true) }.GetNewClosure()
        $draft.Adapters.DownloadAsset = { param($Tag,$Name,$Destination); [IO.File]::Copy((Join-Path $promotion.Root ('remote-' + $Name)),$Destination,$true) }.GetNewClosure()
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        $acceptancePath = Join-Path $acceptance 'CodexRemote-fix-2.5.22-official-draft.complete.json'
        [IO.File]::WriteAllText($acceptancePath, (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $viewCalls = 0
        $draft.Adapters.ViewRelease = {
            param($Tag)
            $viewCalls++
            if ($viewCalls -eq 1) {
                $replacement = [IO.File]::ReadAllText($acceptancePath) | ConvertFrom-Json
                $replacement.completedAtUtc = '2030-02-03T04:05:08.0000000Z'
                [IO.File]::WriteAllText($acceptancePath, (($replacement | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            }
            return [pscustomobject][ordered]@{ Tag = $Tag; Id = [string]$state.DraftId; Draft = [bool]$state.DraftPrivate; AssetNames = @($state.Uploaded) }
        }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        Assert-CcodTrue (-not $state.Promoted -and $state.DraftPrivate) 'a changed final acceptance hash never changes draft visibility'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-promote-defender-evidence-hold' 'Promote holds Defender receipt identity through the visibility mutation' {
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source.Contains('$heldEvidenceHashes[[string]$preflight]')) 'Promote pins the transferred preflight file through the visibility mutation'

    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1DefenderEvidenceHold'
    $assetFixture = $null
    $promotion = $null
    $backup = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $state = $draft.State
        $state | Add-Member -NotePropertyName DefenderReceiptBlocked -NotePropertyValue $false
        $receiptPath = Join-Path $defender $promotion.Names[0]
        $backup = $receiptPath + '.replacement-source'
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            if (-not $Draft) {
                try {
                    [IO.File]::Move($receiptPath, $backup)
                    [IO.File]::Copy($backup, $receiptPath, $false)
                } catch [IO.IOException] {
                    $state.DefenderReceiptBlocked = $true
                }
            }
            $state.DraftPrivate = $Draft
            $state.Promoted = -not $Draft
        }.GetNewClosure()
        $result = Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters
        Assert-CcodTrue ([bool]$result.Promoted -and $state.Promoted) 'Promote completes while Defender receipt identity remains held'
        Assert-CcodTrue $state.DefenderReceiptBlocked 'replacement of a held Defender receipt is blocked during visibility mutation'
    } finally {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            if (Test-Path -LiteralPath ($backup.Substring(0, $backup.Length - '.replacement-source'.Length))) { Remove-Item -LiteralPath ($backup.Substring(0, $backup.Length - '.replacement-source'.Length)) -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $backup -Destination ($backup.Substring(0, $backup.Length - '.replacement-source'.Length)) -Force -ErrorAction SilentlyContinue
        }
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-promote-acceptance-evidence-hold' 'Promote holds acceptance and Verify evidence identity through the visibility mutation' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1AcceptanceEvidenceHold'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        $verificationDirectory = Join-Path $promotion.Root 'verification'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($verificationDirectory) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        $acceptancePath = Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'
        [IO.File]::WriteAllText($acceptancePath, (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $state = $draft.State
        $state | Add-Member -NotePropertyName AcceptanceReplacementBlocked -NotePropertyValue $false
        $state | Add-Member -NotePropertyName VerificationReplacementBlocked -NotePropertyValue $false
        $state | Add-Member -NotePropertyName AcceptanceStateReplacementBlocked -NotePropertyValue $false
        $state | Add-Member -NotePropertyName ManualArtifactReplacementBlocked -NotePropertyValue $false
        $verificationPath = Join-Path $verificationDirectory 'CodexRemote-fix-2.5.22-draft-verified.json'
        $acceptanceStatePath = Join-Path $promotion.Root 'official-draft-acceptance\01-Preflight.json'
        $manualArtifactPath = Join-Path $promotion.Root 'official-draft-artifacts\About\screenshot.bin'
        $draft.Adapters.SetReleaseDraftState = {
            param($Tag, [bool]$Draft)
            if (-not $Draft) {
                try { [IO.File]::AppendAllText($acceptancePath, "tamper`n") } catch [IO.IOException] { $state.AcceptanceReplacementBlocked = $true }
                try { [IO.File]::AppendAllText($verificationPath, "tamper`n") } catch [IO.IOException] { $state.VerificationReplacementBlocked = $true }
                try { [IO.File]::AppendAllText($acceptanceStatePath, "tamper`n") } catch [IO.IOException] { $state.AcceptanceStateReplacementBlocked = $true }
                try { [IO.File]::AppendAllText($manualArtifactPath, "tamper`n") } catch [IO.IOException] { $state.ManualArtifactReplacementBlocked = $true }
            }
            $state.DraftPrivate = $Draft
            $state.Promoted = -not $Draft
        }.GetNewClosure()
        $result = Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters
        Assert-CcodTrue ([bool]$result.Promoted -and $state.Promoted) 'Promote completes while acceptance and Verify evidence identities remain held'
        Assert-CcodTrue $state.AcceptanceReplacementBlocked 'replacement of held acceptance evidence is blocked during visibility mutation'
        Assert-CcodTrue $state.VerificationReplacementBlocked 'replacement of held Verify evidence is blocked during visibility mutation'
        Assert-CcodTrue $state.AcceptanceStateReplacementBlocked 'replacement of held acceptance state is blocked during visibility mutation'
        Assert-CcodTrue $state.ManualArtifactReplacementBlocked 'replacement of held manual artifact is blocked during visibility mutation'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-stage-final-identity' 'Stage rejects a release-object identity swap after the last upload' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1StageFinalIdentity'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = $assetFixture.Outside
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $expected = [string[]]$assetFixture.Names
        $draft.Adapters.ViewRelease = {
            param($Tag)
            $assetNames = [string[]]$state.Uploaded
            $id = if ($assetNames.Count -eq $expected.Count) { '999' } else { '123' }
            [pscustomobject][ordered]@{ Tag = $Tag; Id = $id; Draft = $true; AssetNames = $assetNames }
        }.GetNewClosure()
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_UPLOAD_PRIVATE_RECOVERY_FAILED'
        Assert-CcodTrue (-not $state.Promoted) 'Stage identity swap never promotes the draft'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-defender-plane-required' 'Promote refuses Defender receipts in the shared evidence root' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1DefenderPlane'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-shared-defender-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $result = &$module { param($Evidence) Get-CcodGitHubDraftDefenderEvidenceDirectory $Evidence } $root
        throw 'ASSERT_THROWS: shared Defender evidence root was accepted'
    } catch {
        Assert-CcodTrue ([string]$_.FullyQualifiedErrorId -like 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID*') 'shared evidence root is rejected when the dedicated Defender plane is absent'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-stage-lock' 'default Stage lock serializes same-tag processes and releases after the operation' {
    $scriptPath = Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'
    $source = [IO.File]::ReadAllText($scriptPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source.Contains('if ($defaultLockHeld)') -and -not $source.Contains('if ($null -eq $Adapters -and $defaultLockHeld)')) 'injected Stage and Verify adapters release the same-tag lock in finally'

    $ready = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-lock-ready-' + [guid]::NewGuid().ToString('N'))
    $release = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-lock-release-' + [guid]::NewGuid().ToString('N'))
    $job = $null
    $secondModule = $null
    try {
        $job = Start-Job -ArgumentList $scriptPath, $ready, $release -ScriptBlock {
            param($Path, $ReadyPath, $ReleasePath)
            $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
            $module = New-Module -Name ('CcodLockHolder-' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($text))
            Import-Module $module -Force -DisableNameChecking | Out-Null
            $held = [bool](&$module { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.AcquireStageLock 'v2.5.22' })
            if (-not $held) { throw 'CCOD_TEST_LOCK_HOLDER_FAILED' }
            [IO.File]::WriteAllText($ReadyPath, 'held', [Text.UTF8Encoding]::new($false))
            while (-not [IO.File]::Exists($ReleasePath)) { Start-Sleep -Milliseconds 25 }
            &$module { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.ReleaseStageLock 'v2.5.22' }
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not [IO.File]::Exists($ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-CcodTrue ([IO.File]::Exists($ready)) 'separate lock-holder process acquired the same-tag lock'
        $secondModule = Import-CcodTask6ToolModule -Path $scriptPath -Name 'CcodGitHubDraftReleaseFix1LockSecond'
        $second = [bool](&$secondModule { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.AcquireStageLock 'v2.5.22' })
        Assert-CcodTrue (-not $second) 'second same-tag process is rejected by the default lock'
        [IO.File]::WriteAllText($release, 'release', [Text.UTF8Encoding]::new($false))
        $completed = Wait-Job -Job $job -Timeout 20
        Assert-CcodTrue ($null -ne $completed) 'lock-holder process releases before timeout'
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        $afterModule = Import-CcodTask6ToolModule -Path $scriptPath -Name 'CcodGitHubDraftReleaseFix1LockAfter'
        try {
            $after = [bool](&$afterModule { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.AcquireStageLock 'v2.5.22' })
            Assert-CcodTrue $after 'same-tag lock can be reacquired after the holder releases'
            &$afterModule { $adapters = Get-CcodGitHubDraftReleaseDefaultAdapters; & $adapters.ReleaseStageLock 'v2.5.22' }
        } finally {
            Remove-Module -Name $afterModule.Name -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($null -ne $secondModule) { Remove-Module -Name $secondModule.Name -Force -ErrorAction SilentlyContinue }
        if ($null -ne $job) { Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $ready) { Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $release) { Remove-Item -LiteralPath $release -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix2-operation-lock-release' 'failed Stage Verify and Promote release the real same-tag mutex and reject the old finally mutant' {
    $fixture = $null; $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-operation-lock-' + [guid]::NewGuid().ToString('N'))
    try {
        $fixture = New-CcodTask5ExactAssetFixture
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Write-CcodTask5Json (Join-Path $root 'CodexRemote-fix-2.5.22-clean-preflight.json') ([ordered]@{ schemaVersion = 1; valid = $false; version = '2.5.22'; gitCommit = $fixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) })
        foreach ($mutant in @($false, $true)) {
            foreach ($mode in @('Stage','Verify','Promote')) {
                $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name ('CcodOperationLock-' + [guid]::NewGuid().ToString('N'))
                $job = $null
                try {
                    if ($mutant) {
                        &$module {
                            $source = ${function:Invoke-CcodGitHubDraftReleaseCore}.ToString()
                            $changed = $source.Replace('if ($defaultLockHeld)', 'if ($null -eq $Adapters -and $defaultLockHeld)').Replace('if ($promoteLockHeld)', 'if ($null -eq $Adapters -and $promoteLockHeld)')
                            if ($source -ceq $changed) { throw 'CCOD_TEST_LOCK_MUTANT_NOT_APPLIED' }
                            Set-Item Function:script:Invoke-CcodGitHubDraftReleaseCore -Value ([scriptblock]::Create($changed))
                        }
                    }
                    $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
                    $lockProbe = [pscustomobject]@{ Acquired = $false }
                    $draft.Adapters.TryStageLock = {
                        param($Tag)
                        $lockProbe.Acquired = [bool](&$module { param($Tag) Acquire-CcodGitHubDraftStageLock $Tag } $Tag)
                        return $lockProbe.Acquired
                    }.GetNewClosure()
                    Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode $mode -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $root -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID'
                    Assert-CcodTrue $lockProbe.Acquired "$mode reaches the failure after acquiring the real lock"
                    $mutexName = &$module { Get-CcodGitHubDraftStageLockName 'v2.5.22' }
                    $job = Start-Job -ArgumentList $mutexName -ScriptBlock {
                        param($Name)
                        $mutex = [Threading.Mutex]::new($false, $Name)
                        $held = $false
                        try {
                            try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
                            return [bool]$held
                        } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
                    }
                    $completed = Wait-Job $job -Timeout 20
                    Assert-CcodTrue ($null -ne $completed -and $job.State -ceq 'Completed') "$mode separate-process lock probe completes"
                    $result = @(Receive-Job $job -ErrorAction Stop)
                    Assert-CcodEqual 1 $result.Count 'lock probe returns one explicit result'
                    Assert-CcodTrue ($result[0] -is [bool]) 'lock probe returns a real boolean'
                    Assert-CcodEqual (-not $mutant) $result[0] "$mode reacquires only when the operation finally actually releases"
                } finally {
                    if ($null -ne $job) { Stop-Job $job -ErrorAction SilentlyContinue | Out-Null; Remove-Job $job -Force -ErrorAction SilentlyContinue }
                    &$module { Release-CcodGitHubDraftStageLock 'v2.5.22' }
                    Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } finally {
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
        if ($null -ne $fixture) { Remove-CcodTask5ExactAssetFixture $fixture }
    }
}

Invoke-CcodTask6Test 'fix2-manual-state-before-hold' 'Promote rejects manual state replacement after validation but before holding its bytes' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodPromoteManualStateBeforeHold'
    $fixture = $null; $promotion = $null
    try {
        $fixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $fixture
        $defender = Join-Path $promotion.Root 'defender'; $acceptance = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        [IO.Directory]::CreateDirectory($acceptance) | Out-Null
        foreach ($name in $promotion.Names) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        Write-CcodTask5Json (Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json') ([ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = $fixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) })
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
        $draft.State.Uploaded.AddRange([string[]]$fixture.Names)
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Write-CcodTask5Json (Join-Path $acceptance 'CodexRemote-fix-2.5.22-official-draft.complete.json') (New-CcodTask9AcceptanceRecord -AssetFixture $fixture -EvidenceRoot $promotion.Root)
        $probe = [pscustomobject]@{ Reads = 0; Replaced = $false }
        &$module {
            param($Path,$Probe)
            $script:CcodManualStatePath = $Path; $script:CcodManualStateProbe = $Probe
            $script:CcodOriginalAcceptanceReader = ${function:Read-CcodGitHubDraftAcceptance}
            Set-Item Function:script:Read-CcodGitHubDraftAcceptance -Value {
                param($EvidenceDirectory,$AssetDirectory,$Tag,$Version,$GitCommit)
                $record = & $script:CcodOriginalAcceptanceReader @PSBoundParameters
                $script:CcodManualStateProbe.Reads++
                if ($script:CcodManualStateProbe.Reads -eq 2) {
                    [IO.File]::WriteAllText($script:CcodManualStatePath, '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
                    $script:CcodManualStateProbe.Replaced = $true
                }
                return $record
            }
        } (Join-Path $promotion.Root 'official-draft-acceptance/manual-evidence/TrayEvidence-About.json') $probe
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        Assert-CcodTrue $probe.Replaced 'replacement occurs after the final unlocked acceptance read'
        Assert-CcodTrue (-not $draft.State.Promoted) 'invalid manual state cannot change public visibility'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and [IO.Directory]::Exists($promotion.Root)) { [IO.Directory]::Delete($promotion.Root, $true) }
        if ($null -ne $fixture) { Remove-CcodTask5ExactAssetFixture $fixture }
    }
}

Invoke-CcodTask6Test 'fix2-preflight-pinned-hash' 'Promote rejects same-meaning preflight replacement after its pinned read' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') -Name 'CcodPromotePinnedPreflight'
    $fixture = $null; $promotion = $null
    try {
        $fixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $fixture
        $defender = Join-Path $promotion.Root 'defender'
        $acceptance = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        [IO.Directory]::CreateDirectory($acceptance) | Out-Null
        foreach ($name in $promotion.Names) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflight = Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'
        Write-CcodTask5Json $preflight ([ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = $fixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) })
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
        $draft.State.Uploaded.AddRange([string[]]$fixture.Names)
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Write-CcodTask5Json (Join-Path $acceptance 'CodexRemote-fix-2.5.22-official-draft.complete.json') (New-CcodTask9AcceptanceRecord -AssetFixture $fixture -EvidenceRoot $promotion.Root)
        $probe = [pscustomobject]@{ Replaced = $false }
        &$module {
            param($Path,$Probe)
            $script:CcodPinnedPreflightPath = $Path
            $script:CcodPinnedPreflightProbe = $Probe
            $script:CcodOriginalPinnedReader = ${function:Read-CcodGitHubDraftContractJson}
            Set-Item Function:script:Read-CcodGitHubDraftContractJson -Value {
                param($Path,$ErrorId)
                $document = & $script:CcodOriginalPinnedReader -Path $Path -ErrorId $ErrorId
                if ($Path -ceq $script:CcodPinnedPreflightPath -and -not $script:CcodPinnedPreflightProbe.Replaced) {
                    [IO.File]::AppendAllText($Path, ' ', [Text.UTF8Encoding]::new($false))
                    $script:CcodPinnedPreflightProbe.Replaced = $true
                }
                return $document
            }
        } $preflight $probe
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID'
        Assert-CcodTrue $probe.Replaced 'replacement lands after the validated pinned read'
        Assert-CcodTrue (-not $draft.State.Promoted) 'no visibility mutation occurs for changed preflight bytes'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and [IO.Directory]::Exists($promotion.Root)) { [IO.Directory]::Delete($promotion.Root, $true) }
        if ($null -ne $fixture) { Remove-CcodTask5ExactAssetFixture $fixture }
    }
}

Invoke-CcodTask6Test 'fix1-evidence-layout' 'Promote accepts separate Defender receipts, verification, and acceptance evidence and reads the final draft state back' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1Evidence'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $verification = Join-Path $promotion.Root 'verification'
        $acceptance = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        [IO.Directory]::CreateDirectory($verification) | Out-Null
        [IO.Directory]::CreateDirectory($acceptance) | Out-Null
        foreach ($name in @($promotion.Names)) {
            Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name)
        }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.File]::WriteAllText((Join-Path $acceptance 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $result = Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters
        Assert-CcodTrue ([bool]$result.Promoted) 'promotion succeeds with separated evidence planes'
        Assert-CcodTrue (-not $draft.State.DraftPrivate) 'promotion changes the already verified draft to public'
        Assert-CcodTrue (-not $draft.State.Rebuilt) 'promotion never rebuilds the candidate'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-workflow-transfer' 'release workflow transfers one immutable commit and the clean preflight as artifacts without rerunning the runner in Stage' {
    $workflowPath = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $raw = [IO.File]::ReadAllText($workflowPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($raw.Contains('commit:')) 'preflight publishes an immutable commit output'
    Assert-CcodTrue ($raw.Contains('ref: ${{ needs.preflight.outputs.commit }}')) 'build and stage use the immutable preflight commit'
    Assert-CcodTrue ($raw.Contains('-NotesPath $notesPath')) 'generated release notes are passed to draft creation'
    Assert-CcodTrue ([regex]::Matches($raw, 'actions/upload-artifact@').Count -ge 2) 'preflight and candidate are transferred as separate artifacts'
    Assert-CcodTrue ([regex]::Matches($raw, 'actions/download-artifact@').Count -ge 2) 'stage downloads both immutable artifacts'
    Assert-CcodEqual 1 ([regex]::Matches($raw, 'Test-CcodCleanReleaseRunner').Count) 'Stage does not rerun clean runner as a substitute for transferred evidence'
}

Invoke-CcodTask6Test 'fix1-runner-defaults' 'default clean runner adapters fail closed on git failure and preflight evidence is create-only with readback' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Test-CleanReleaseRunner.ps1') -Name 'CcodCleanReleaseRunnerFix1Defaults'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task6-runner-defaults-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $adapters = &$module { Get-CcodCleanReleaseRunnerDefaultAdapters }
        Assert-CcodThrows { & $adapters.GetGitPorcelain $root | Out-Null } 'CCOD_CLEAN_RUNNER_INSPECTION_FAILED'
        $evidence = Join-Path $root 'preflight.json'
        $record = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = ('c' * 40); repositoryRoot = $root }
        & $adapters.WritePreflightEvidence $evidence $record | Out-Null
        Assert-CcodTrue (Test-Path -LiteralPath $evidence -PathType Leaf) 'default preflight writer creates its evidence file'
        Assert-CcodThrows { & $adapters.WritePreflightEvidence $evidence $record | Out-Null } 'CCOD_CLEAN_RUNNER_PREFLIGHT_WRITE_FAILED'
        $written = [IO.File]::ReadAllText($evidence, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        Assert-CcodEqual $record.gitCommit ([string]$written.gitCommit) 'preflight writer readback retains the exact commit'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-evidence-types' 'persisted Verify and acceptance records reject scalar fields encoded as single-element arrays' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1EvidenceTypes'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = Join-Path $assetFixture.Outside 'typed-evidence'
        $acceptanceDirectory = Join-Path $evidence 'acceptance'
        $verificationDirectory = Join-Path $evidence 'verification'
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($verificationDirectory) | Out-Null
        $manifestHash = Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $assetFixture.Names[4])
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot $evidence
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        &$module {param($Evidence,$Assets,$Commit)Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit|Out-Null} $evidence $assetFixture.Root $assetFixture.GitCommit
        [Console]::WriteLine('CCOD_ACCEPTANCE_SCALAR_CONTROL_PASSED')
        $acceptanceRecord.version=@('2.5.22')
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            &$module { param($Evidence,$Assets,$Tag,$Version,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version $Version -GitCommit $Commit } $evidence $assetFixture.Root 'v2.5.22' '2.5.22' $assetFixture.GitCommit | Out-Null
        } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        $names = [string[]]$assetFixture.Names
        $originalAcceptance=&$module {${function:Read-CcodGitHubDraftAcceptance}}
        try {
            &$module {
                param($Original)
                $body=$Original.ToString();$guard='$record.version -isnot [string] -or '
                Assert-CcodTrue (([regex]::Matches($body,[regex]::Escape($guard))).Count-eq1) 'one acceptance version type guard exists'
                Set-Item -LiteralPath Function:script:Read-CcodGitHubDraftAcceptance -Value ([scriptblock]::Create($body.Replace($guard,'')))
            } $originalAcceptance
            &$module {param($Evidence,$Assets,$Commit)Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit|Out-Null} $evidence $assetFixture.Root $assetFixture.GitCommit
            [Console]::WriteLine('CCOD_ACCEPTANCE_VERSION_GUARD_REMOVAL_REACHED')
        } finally {&$module {param($Original)Set-Item -LiteralPath Function:script:Read-CcodGitHubDraftAcceptance -Value $Original} $originalAcceptance}
        $hashes = [Collections.Generic.List[string]]::new()
        foreach ($name in $names) { $hashes.Add((Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $name))) }
        $verificationRecord = [ordered]@{
            schemaVersion = 1
            kind = 'github-draft-verification'
            tag = 'v2.5.22'
            draftId = '123'
            version = '2.5.22'
            gitCommit = [string]$assetFixture.GitCommit
            draft = $true
            verified = $true
            assetNames = $names
            assetSha256 = [string[]]$hashes
            candidateManifestSha256 = $manifestHash
        }
        [IO.File]::WriteAllText((Join-Path $verificationDirectory 'CodexRemote-fix-2.5.22-draft-verified.json'), (($verificationRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        &$module {param($Evidence,$Assets,$Commit)Read-CcodGitHubDraftVerification -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit|Out-Null} $evidence $assetFixture.Root $assetFixture.GitCommit
        [Console]::WriteLine('CCOD_VERIFY_SCALAR_CONTROL_PASSED')
        $verificationRecord.tag=@('v2.5.22')
        [IO.File]::WriteAllText((Join-Path $verificationDirectory 'CodexRemote-fix-2.5.22-draft-verified.json'), (($verificationRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            &$module { param($Evidence,$Assets,$Tag,$Version,$Commit) Read-CcodGitHubDraftVerification -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version $Version -GitCommit $Commit } $evidence $assetFixture.Root 'v2.5.22' '2.5.22' $assetFixture.GitCommit | Out-Null
        } 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID'
        $verificationRecord.tag = 'v2.5.22'
        [IO.File]::WriteAllText((Join-Path $verificationDirectory 'CodexRemote-fix-2.5.22-draft-verified.json'), (($verificationRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        &$module {param($Evidence,$Assets,$Commit)Read-CcodGitHubDraftVerification -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit|Out-Null} $evidence $assetFixture.Root $assetFixture.GitCommit
        $malformedNames = New-Object object[] $names.Count
        $nestedName = New-Object object[] 1
        $nestedName[0] = $names[0]
        $malformedNames[0] = $nestedName
        for ($index = 1; $index -lt $names.Count; $index++) { $malformedNames[$index] = $names[$index] }
        $malformedRecord = [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'github-draft-verification'
            tag = 'v2.5.22'
            draftId = '123'
            version = '2.5.22'
            gitCommit = [string]$assetFixture.GitCommit
            draft = $true
            verified = $true
            assetNames = $malformedNames
            assetSha256 = [string[]]$hashes
            candidateManifestSha256 = $manifestHash
        }
        &$module { param($Value) Set-Item Function:Read-CcodGitHubDraftContractJson -Value { param($JsonPath,$ErrorId) [pscustomobject]@{ Raw = '{}'; Value = $Value } }.GetNewClosure() } $malformedRecord
        Assert-CcodThrows {
            &$module { param($Evidence,$Assets,$Tag,$Version,$Commit) Read-CcodGitHubDraftVerification -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version $Version -GitCommit $Commit } $evidence $assetFixture.Root 'v2.5.22' '2.5.22' $assetFixture.GitCommit | Out-Null
        } 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'review-verify-frozen-authority' 'Verify never attests a frozen asset changed after its remote comparison' {
    foreach ($attack in @($false,$true)) {
        $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name ('CcodVerifyFrozenAuthority'+[guid]::NewGuid().ToString('N'))
        $fixture = $null
        try {
            $fixture = New-CcodTask5ExactAssetFixture
            $preflight = [ordered]@{schemaVersion=1;valid=$true;version='2.5.22';gitCommit=$fixture.GitCommit;repositoryRoot=[IO.Path]::GetFullPath($repositoryRoot)}
            Write-CcodTask5Json -Path (Join-Path $fixture.Outside 'CodexRemote-fix-2.5.22-clean-preflight.json') -Value $preflight
            $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
            Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $fixture.Outside -Adapters $draft.Adapters | Out-Null
            $firstName = [string]$fixture.Names[0]
            $originalHash = Get-CcodTestFileSha256 (Join-Path $fixture.Root $firstName)
            $state = [pscustomobject]@{Frozen=$null;Downloads=0;Attempted=$false;Changed=$false;Attack=$attack;Names=[string[]]$fixture.Names;RemoteRoot=$fixture.Root}
            & $module {
                param($State)
                $script:CcodVerifyFreezeState=$State
                $script:CcodVerifyOriginalFreeze=${function:New-CcodGitHubDraftFrozenAssetSet}
                function script:New-CcodGitHubDraftFrozenAssetSet {
                    param($AssetDirectory,$Version,$Contract)
                    $result=& $script:CcodVerifyOriginalFreeze -AssetDirectory $AssetDirectory -Version $Version -Contract $Contract
                    $script:CcodVerifyFreezeState.Frozen=$result.Directory
                    return $result
                }
            } $state
            $draft.Adapters.DownloadAsset = {
                param($Tag,$Name,$Destination)
                [IO.File]::Copy((Join-Path $state.RemoteRoot $Name),$Destination,$false)
                $state.Downloads++
                if ($state.Attack -and $state.Downloads -eq $state.Names.Count) {
                    $state.Attempted=$true
                    [IO.File]::WriteAllText((Join-Path $state.Frozen $state.Names[0]),'changed after the earlier comparison',[Text.UTF8Encoding]::new($false))
                    $state.Changed=$true
                }
            }.GetNewClosure()
            $outcome = try {
                $result = Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $fixture.Outside -Adapters $draft.Adapters
                [pscustomobject]@{Success=$true;Result=$result;ErrorId=$null}
            } catch { [pscustomobject]@{Success=$false;Result=$null;ErrorId=$_.FullyQualifiedErrorId} }
            Assert-CcodEqual $fixture.Names.Count $state.Downloads 'all remote comparisons are reached before the mutation seam'
            Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($state.Frozen)) 'the actual production freeze helper was invoked'
            if (-not $attack) {
                Assert-CcodTrue $outcome.Success 'an unchanged frozen candidate has a passing control'
                $receipt = [IO.File]::ReadAllText($outcome.Result.VerificationPath) | ConvertFrom-Json
                Assert-CcodEqual $originalHash $receipt.assetSha256[0] 'the control attests the original remote bytes'
                $manifestName = & $module { Get-CcodGitHubDraftManifestName '2.5.22' }
                Assert-CcodEqual (Get-CcodTestFileSha256 (Join-Path $fixture.Root $manifestName)) $receipt.candidateManifestSha256 'the candidate manifest hash remains bound to the initially validated bytes'
                [Console]::WriteLine('CCOD_VERIFY_FROZEN_CONTROL_PASSED')
            } else {
                Assert-CcodTrue $state.Attempted 'the writer reaches an already-compared frozen asset'
                Assert-CcodTrue (-not $outcome.Success) 'Verify must not mark changed local bytes as remotely verified'
                Assert-CcodTrue (-not $state.Changed) 'the held frozen file excludes the writer'
                Assert-CcodTrue ($outcome.ErrorId -like 'CCOD_GITHUB_DRAFT_READBACK_FAILED*') 'the failed download boundary stays fail-closed'
            }
            Assert-CcodTrue (-not [IO.Directory]::Exists($state.Frozen)) 'frozen handles are released before temporary cleanup'
        } finally {
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
            if ($null -ne $fixture) { Remove-CcodTask5ExactAssetFixture $fixture }
        }
    }
}

Invoke-CcodTask6Test 'review-verify-ancestor' 'Verify excludes ancestor rename while comparing frozen assets' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name ('CcodVerifyAncestor'+[guid]::NewGuid().ToString('N'))
    $fixture = $null
    try {
        $fixture = New-CcodTask5ExactAssetFixture
        Write-CcodTask5Json -Path (Join-Path $fixture.Outside 'CodexRemote-fix-2.5.22-clean-preflight.json') -Value ([ordered]@{schemaVersion=1;valid=$true;version='2.5.22';gitCommit=$fixture.GitCommit;repositoryRoot=[IO.Path]::GetFullPath($repositoryRoot)})
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $fixture.Outside -Adapters $draft.Adapters | Out-Null
        $parent = Join-Path $fixture.Outside 'owned-freeze-parent'
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        $state = [pscustomobject]@{Parent=$parent;Frozen=$null;Downloads=0;Attempted=$false;Renamed=$false;Names=[string[]]$fixture.Names;RemoteRoot=$fixture.Root}
        & $module {
            param($State)
            $script:CcodVerifyAncestorState=$State
            $script:CcodVerifyOriginalFreeze=${function:New-CcodGitHubDraftFrozenAssetSet}
            function script:New-CcodGitHubDraftFrozenAssetSet {
                param($AssetDirectory,$Version,$Contract)
                $result=& $script:CcodVerifyOriginalFreeze -AssetDirectory $AssetDirectory -Version $Version -Contract $Contract
                $target=Join-Path $script:CcodVerifyAncestorState.Parent 'frozen'
                [IO.Directory]::Move($result.Directory,$target)
                $result.Directory=$target
                $script:CcodVerifyAncestorState.Frozen=$target
                return $result
            }
        } $state
        $draft.Adapters.DownloadAsset = {
            param($Tag,$Name,$Destination)
            [IO.File]::Copy((Join-Path $state.RemoteRoot $Name),$Destination,$false)
            $state.Downloads++
            if ($state.Downloads -eq $state.Names.Count) {
                $state.Attempted=$true
                $moved=$state.Parent+'.moved'
                try {[IO.Directory]::Move($state.Parent,$moved);$state.Renamed=$true}
                finally {if($state.Renamed){[IO.Directory]::Move($moved,$state.Parent)}}
            }
        }.GetNewClosure()
        $outcome = try {
            Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $fixture.Outside -Adapters $draft.Adapters | Out-Null
            [pscustomobject]@{Success=$true;ErrorId=$null}
        } catch {[pscustomobject]@{Success=$false;ErrorId=$_.FullyQualifiedErrorId}}
        Assert-CcodEqual $fixture.Names.Count $state.Downloads 'the real held comparison path reaches its last download'
        Assert-CcodTrue $state.Attempted 'only the fixture-owned ancestor was targeted'
        Assert-CcodTrue (-not $state.Renamed) 'frozen ancestor authority excludes an ABA rename'
        Assert-CcodTrue (-not $outcome.Success) 'the blocked adapter operation cannot produce verification evidence'
        Assert-CcodTrue ($outcome.ErrorId -like 'CCOD_GITHUB_DRAFT_READBACK_FAILED*') 'ancestor failure is not disguised as an unrelated fixture error'
        Assert-CcodTrue (-not [IO.Directory]::Exists($state.Frozen)) 'the frozen subtree is cleaned after releasing authorities'
        [IO.Directory]::Move($parent,$parent+'.released')
        [IO.Directory]::Move($parent+'.released',$parent)
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $fixture) {Remove-CcodTask5ExactAssetFixture $fixture}
    }
}

Invoke-CcodTask6Test 'review-verify-authority-boundaries' 'Verify pins original bytes before callbacks and holds them through receipt readback' {
    foreach ($mode in @('Control','ChangedBeforePin','ExistingWriter','ReceiptWrite','ReceiptDirectory')) {
        $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name ('CcodVerifyAuthorityBoundary'+[guid]::NewGuid().ToString('N'))
        $fixture=$null;$state=$null
        try {
            $fixture=New-CcodTask5ExactAssetFixture
            Write-CcodTask5Json -Path (Join-Path $fixture.Outside 'CodexRemote-fix-2.5.22-clean-preflight.json') -Value ([ordered]@{schemaVersion=1;valid=$true;version='2.5.22';gitCommit=$fixture.GitCommit;repositoryRoot=[IO.Path]::GetFullPath($repositoryRoot)})
            $draft=New-CcodTask6DraftAdapterFixture -AssetDirectory $fixture.Root
            Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $fixture.Outside -Adapters $draft.Adapters | Out-Null
            $receiptPath=& $module {param($Root) Get-CcodGitHubDraftVerificationPath $Root '2.5.22' -CreatePlane} $fixture.Outside
            $state=[pscustomobject]@{Mode=$mode;Frozen=$null;Writer=$null;Names=[string[]]$fixture.Names;Downloads=0;RemoteRoot=$fixture.Root;Attempted=$false;Changed=$false;PublishedSeen=$false;Receipt=$receiptPath}
            & $module {
                param($State)
                $script:CcodVerifyBoundaryState=$State
                $script:CcodVerifyOriginalFreeze=${function:New-CcodGitHubDraftFrozenAssetSet}
                function script:New-CcodGitHubDraftFrozenAssetSet {
                    param($AssetDirectory,$Version,$Contract)
                    $result=& $script:CcodVerifyOriginalFreeze -AssetDirectory $AssetDirectory -Version $Version -Contract $Contract
                    $script:CcodVerifyBoundaryState.Frozen=$result.Directory
                    $target=Join-Path $result.Directory $script:CcodVerifyBoundaryState.Names[1]
                    if ($script:CcodVerifyBoundaryState.Mode -ceq 'ChangedBeforePin') {
                        [IO.File]::WriteAllText($target,'changed before pin',[Text.UTF8Encoding]::new($false))
                        $script:CcodVerifyBoundaryState.Attempted=$true
                    }
                    if ($script:CcodVerifyBoundaryState.Mode -ceq 'ExistingWriter') {
                        $script:CcodVerifyBoundaryState.Writer=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                        $script:CcodVerifyBoundaryState.Attempted=$true
                    }
                    return $result
                }
            } $state
            $draft.Adapters.DownloadAsset={param($Tag,$Name,$Destination) $state.Downloads++;[IO.File]::Copy((Join-Path $state.RemoteRoot $Name),$Destination,$false)}.GetNewClosure()
            $draft.Adapters.GetTagCommit={
                param($Tag,[bool]$ActionsOnly)
                if ($state.Mode -in @('ReceiptWrite','ReceiptDirectory') -and [IO.File]::Exists($state.Receipt)) {
                    $state.PublishedSeen=$true;$state.Attempted=$true
                    if ($state.Mode -ceq 'ReceiptWrite') {
                        [IO.File]::WriteAllText((Join-Path $state.Frozen $state.Names[0]),'changed during receipt readback',[Text.UTF8Encoding]::new($false));$state.Changed=$true
                    } else {
                        try {[IO.Directory]::Move($state.Frozen,$state.Frozen+'.moved');$state.Changed=$true}
                        finally {if($state.Changed){[IO.Directory]::Move($state.Frozen+'.moved',$state.Frozen)}}
                    }
                }
                return 'c'*40
            }.GetNewClosure()
            $outcome=try {
                $result=Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $fixture.Root -EvidenceDirectory $fixture.Outside -Adapters $draft.Adapters
                [pscustomobject]@{Success=$true;ErrorId=$null;Result=$result}
            } catch {[pscustomobject]@{Success=$false;ErrorId=$_.FullyQualifiedErrorId;Result=$null}}
            if ($mode -ceq 'Control') {
                Assert-CcodTrue $outcome.Success 'an unchanged candidate verifies before introducing any boundary fault'
                Assert-CcodTrue ([IO.File]::Exists($receiptPath)) 'the control produces a verification receipt'
            } else {
                Assert-CcodTrue $state.Attempted "$mode reaches its intended mutation seam"
                Assert-CcodTrue (-not $outcome.Success) "$mode cannot yield a successful Verify"
                Assert-CcodTrue (-not [IO.File]::Exists($receiptPath)) "$mode leaves no verification receipt"
                if ($mode -in @('ChangedBeforePin','ExistingWriter')) {
                    Assert-CcodEqual 0 $state.Downloads 'invalid or writable frozen bytes are rejected before download comparisons'
                    Assert-CcodTrue ($outcome.ErrorId -like 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED*') 'the acquisition rejects the exact asset authority'
                } else {
                    Assert-CcodEqual $fixture.Names.Count $state.Downloads 'the published-receipt probe follows all remote comparisons'
                    Assert-CcodTrue $state.PublishedSeen 'readback failure is injected only after actual receipt publication'
                    Assert-CcodTrue (-not $state.Changed) 'the held file/directory blocks the callback mutation'
                    Assert-CcodTrue ($outcome.ErrorId -like 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID*') "owned evidence rollback retains the plane-specific error mode=$mode actual=$($outcome.ErrorId)"
                }
            }
            if ($null -ne $state.Writer) {$state.Writer.Dispose();$state.Writer=$null}
            Assert-CcodTrue (-not [IO.Directory]::Exists($state.Frozen)) 'partial and complete authority acquisition both release before cleanup'
        } finally {
            if ($null -ne $state -and $null -ne $state.Writer) {$state.Writer.Dispose()}
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
            if ($null -ne $fixture) {Remove-CcodTask5ExactAssetFixture $fixture}
        }
    }
}

Invoke-CcodTask6Test 'review-verify-rejected-receipt' 'A rejected draft receipt closes its deleted handle before proving absence' {
    $module=Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name ('CcodRejectedDraftReceipt'+[guid]::NewGuid().ToString('N'))
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-receipt-rejection-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        $record=[ordered]@{schemaVersion=1;kind='synthetic-self-test'}
        $good=Join-Path $root 'control.json'
        & $module {param($Path,$Record) Write-CcodGitHubDraftJsonCreateOnly -Path $Path -Record $Record -ErrorId 'CCOD_TEST_VERIFY_WRITE_FAILED' -ReadbackVerifier {param($PublishedPath) return $true} | Out-Null} $good $record
        Assert-CcodTrue ([IO.File]::Exists($good)) 'a valid control publishes and reads back successfully'
        $target=Join-Path $root 'rejected.json'
        $state=[pscustomobject]@{Calls=0;PublishedSeen=$false}
        $reject={param($Path) $state.Calls++;$state.PublishedSeen=[IO.File]::Exists($Path);return $false}.GetNewClosure()
        Assert-CcodThrows {
            & $module {param($Path,$Record,$Verifier) Write-CcodGitHubDraftJsonCreateOnly -Path $Path -Record $Record -ErrorId 'CCOD_TEST_VERIFY_WRITE_FAILED' -ReadbackVerifier $Verifier | Out-Null} $target $record $reject
        } 'CCOD_TEST_VERIFY_WRITE_FAILED'
        Assert-CcodEqual 1 $state.Calls 'the callback rejects exactly one actual publication'
        Assert-CcodTrue $state.PublishedSeen 'the callback does not delete or hide the file itself'
        Assert-CcodTrue (-not [IO.File]::Exists($target)) 'production cleanup proves its rejected receipt absent'
        Assert-CcodTrue ([IO.File]::Exists($good)) 'cleanup preserves the unrelated control receipt'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ([IO.Directory]::Exists($root)) {Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTask6Test 'fix1-freeze-assets' 'Stage uploads the exact candidate bytes even when a source asset changes after validation' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1FreezeAssets'
    $assetFixture = $null
    $uploadedRoot = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = Join-Path $assetFixture.Outside 'freeze-assets'
        [IO.Directory]::CreateDirectory($evidence) | Out-Null
        $expected = [string[]]$assetFixture.Names
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $originalHash = Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $expected[0])
        $uploadedRoot = Join-Path $assetFixture.Outside 'uploaded'
        [IO.Directory]::CreateDirectory($uploadedRoot) | Out-Null
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $state = $draft.State
        $sourceRoot = $assetFixture.Root
        $hashFile = {
            param($Path)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $stream = [IO.File]::OpenRead($Path)
                try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose() }
            } finally { $sha.Dispose() }
        }.GetNewClosure()
        $draft.Adapters.CreateDraft = {
            param($Tag, $Title, $Notes)
            [IO.File]::WriteAllText((Join-Path $sourceRoot $expected[0]), 'mutated-after-exact-set', [Text.UTF8Encoding]::new($false))
            $state.Created = $true
            $state.DraftPrivate = $true
            [pscustomobject][ordered]@{ Tag = $Tag; Id = [string]$state.DraftId; Draft = $true; AssetNames = @() }
        }.GetNewClosure()
        $draft.Adapters.UploadAsset = {
            param($Tag, $Name, $Path)
            $destination = Join-Path $uploadedRoot $Name
            [IO.File]::Copy($Path, $destination, $true)
            $state.Uploaded.Add($Name)
            $state.Assets[$Name] = & $hashFile $destination
        }.GetNewClosure()
        $draft.Adapters.DownloadAsset = {
            param($Tag, $Name, $Destination)
            [IO.File]::Copy((Join-Path $uploadedRoot $Name), $Destination, $true)
        }.GetNewClosure()
        $notesFile = Join-Path $assetFixture.Outside 'notes.txt'
        [IO.File]::WriteAllText($notesFile, 'outside notes', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters -NotesPath $notesFile | Out-Null } 'CCOD_GITHUB_DRAFT_NOTES_INVALID'
        Invoke-CcodTask6DraftCore -Module $module -Mode Stage -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $draft.Adapters | Out-Null
        Assert-CcodEqual $originalHash ([string]$state.Assets[$expected[0]]) 'Stage uploads the pre-validation bytes rather than the raced source bytes'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-promote-lock' 'Promote refuses an occupied same-tag lock before changing draft visibility' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1PromoteLock'
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source.Contains('$frozen = $null')) 'Promote initializes frozen state before any failure-prone acquisition'
    $assetFixture = $null
    $promotion = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $promotion = New-CcodTask5PromotionFixture $assetFixture
        $defender = Join-Path $promotion.Root 'defender'
        $acceptanceDirectory = Join-Path $promotion.Root 'acceptance'
        [IO.Directory]::CreateDirectory($defender) | Out-Null
        foreach ($name in @($promotion.Names)) { Move-Item -LiteralPath (Join-Path $promotion.Root $name) -Destination (Join-Path $defender $name) }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $promotion.Root 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $expected = [string[]]$assetFixture.Names
        $draft = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $draft.State.Uploaded.AddRange($expected)
        Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $draft.Adapters.TryStageLock = { param($Tag) $false }.GetNewClosure()
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Promote -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $promotion.Root -Adapters $draft.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_CONCURRENT'
        Assert-CcodTrue (-not $draft.State.Promoted) 'occupied Promote lock never changes visibility'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion.Root)) { Remove-Item -LiteralPath $promotion.Root -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-evidence-paths' 'verification and acceptance evidence reject junction ancestry outside the evidence root' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseFix1EvidencePaths'
    $assetFixture = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = Join-Path $assetFixture.Outside 'evidence-paths'
        $verificationOutside = Join-Path $assetFixture.Outside 'verification-outside'
        $acceptanceOutside = Join-Path $assetFixture.Outside 'acceptance-outside'
        [IO.Directory]::CreateDirectory($evidence) | Out-Null
        [IO.Directory]::CreateDirectory($verificationOutside) | Out-Null
        [IO.Directory]::CreateDirectory($acceptanceOutside) | Out-Null
        $verificationLink = Join-Path $evidence 'verification'
        $acceptanceLink = Join-Path $evidence 'acceptance'
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & cmd.exe /d /c mklink /J $verificationLink $verificationOutside 2>&1 | Out-Null
            $verificationCode = $LASTEXITCODE
            & cmd.exe /d /c mklink /J $acceptanceLink $acceptanceOutside 2>&1 | Out-Null
            $acceptanceCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        if ($verificationCode -ne 0 -or $acceptanceCode -ne 0) { throw 'evidence path junction fixture failed' }
        $preflightRecord = [ordered]@{ schemaVersion = 1; valid = $true; version = '2.5.22'; gitCommit = [string]$assetFixture.GitCommit; repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot) }
        [IO.File]::WriteAllText((Join-Path $evidence 'CodexRemote-fix-2.5.22-clean-preflight.json'), (($preflightRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $expected = [string[]]$assetFixture.Names
        $verify = New-CcodTask6DraftAdapterFixture -AssetDirectory $assetFixture.Root
        $verify.State.Uploaded.AddRange($expected)
        Assert-CcodThrows {
            Invoke-CcodTask6DraftCore -Module $module -Mode Verify -Tag 'v2.5.22' -AssetDirectory $assetFixture.Root -EvidenceDirectory $evidence -Adapters $verify.Adapters | Out-Null
        } 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $verificationOutside 'CodexRemote-fix-2.5.22-draft-verified.json') -PathType Leaf)) 'Verify does not write through an external verification junction'
        $acceptanceRecord = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        [IO.File]::WriteAllText((Join-Path $acceptanceOutside 'CodexRemote-fix-2.5.22-official-draft.complete.json'), (($acceptanceRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            &$module { param($Evidence,$Assets,$Tag,$Version,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version $Version -GitCommit $Commit } $evidence $assetFixture.Root 'v2.5.22' '2.5.22' $assetFixture.GitCommit | Out-Null
        } 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-notes-pinned-read' 'Stage reads approved release notes through a held file authority' {
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'), [Text.UTF8Encoding]::new($false))
    $start = $source.IndexOf('if (-not [string]::IsNullOrWhiteSpace($NotesPath))')
    $end = $source.IndexOf('$expected = [string[]]$frozen.Names', $start)
    Assert-CcodTrue ($start -ge 0 -and $end -gt $start) 'Stage notes block is present'
    $block = $source.Substring($start, $end - $start)
    Assert-CcodTrue ($block.Contains('Read-CcodGitHubDraftNotesPinned')) 'Stage notes use the pinned authority reader'
    Assert-CcodTrue (-not $block.Contains('[IO.File]::ReadAllText($notesFile')) 'Stage notes do not reopen the pathname directly'
}

Invoke-CcodTask6Test 'fix1-concurrency-canonical' 'workflow dispatch rejects whitespace tag variants instead of normalizing them after concurrency grouping' {
    $releasePath = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $raw = [IO.File]::ReadAllText($releasePath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($raw -cnotmatch '\$tag\s*=\s*\$tag\.Trim\(\)') 'dispatch tag is validated without post-group normalization'
}

Invoke-CcodTask6Test 'fix2-defender-absolute' 'Defender entrypoint version commit and artifact digest reject trailing newlines before scan' {
    $module = Import-Module $releaseDefenderModulePath -Force -PassThru -DisableNameChecking
    try {
        $commands = @((Get-Command $defenderPath), (&$module { Get-Command Invoke-CcodReleaseDefenderCheck }), (&$module { Get-Command Invoke-CcodReleaseDefenderCheckCore }))
        foreach ($command in $commands) {
            foreach ($parameter in @('ExpectedVersion','ExpectedGitCommit')) {
                $value = if ($parameter -ceq 'ExpectedVersion') { '2.5.22' } else { 'a' * 40 }
                $patterns = @($command.Parameters[$parameter].Attributes | Where-Object { $_ -is [Management.Automation.ValidatePatternAttribute] })
                Assert-CcodEqual 1 $patterns.Count "$($command.Name) has one strict $parameter validator"
                Assert-CcodTrue ([regex]::IsMatch($value, $patterns[0].RegexPattern)) 'canonical input remains valid'
                foreach ($suffix in @("`n","`r`n",' ')) {
                    Assert-CcodTrue (-not [regex]::IsMatch($value + $suffix, $patterns[0].RegexPattern)) "$($command.Name) $parameter rejects a noncanonical suffix"
                }
            }
        }
        $identity = New-CcodTask5WorkflowIdentity
        $valid = &$module { param($Identity) Assert-CcodReleaseDefenderOrigin -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $Identity -ExpectedGitCommit ('a' * 40) } $identity
        Assert-CcodEqual $identity.artifactDigest $valid.artifactDigest 'canonical workflow digest remains valid'
        $identity.artifactDigest += "`n"
        Assert-CcodThrows {
            &$module { param($Identity) Assert-CcodReleaseDefenderOrigin -Origin TrustedWorkflowArtifact -WorkflowArtifactIdentity $Identity -ExpectedGitCommit ('a' * 40) } $identity | Out-Null
        } 'CCOD_DEFENDER_ORIGIN_INVALID'
    } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
}

Invoke-CcodTask6Test 'fix1-absolute-tag-anchor' 'release tag and version validators reject trailing newline variants' {
    $release = [IO.File]::ReadAllText((Join-Path $repositoryRoot '.github/workflows/release.yml'), [Text.UTF8Encoding]::new($false))
    $draft = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1'), [Text.UTF8Encoding]::new($false))
    $clean = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/Test-CleanReleaseRunner.ps1'), [Text.UTF8Encoding]::new($false))
    $assetContract = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tools/ReleaseAssetContract.psm1'), [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($release.Contains('^v\d+\.\d+\.\d+\z')) 'release workflow uses an absolute tag end anchor'
    Assert-CcodTrue ($draft.Contains('^v\d+\.\d+\.\d+\z')) 'draft command uses an absolute tag end anchor'
    Assert-CcodTrue ($clean.Contains('^\d+\.\d+\.\d+\z')) 'clean runner uses an absolute version end anchor'
    Assert-CcodTrue (-not $assetContract.Contains('^\d+\.\d+\.\d+$')) 'release asset contract has no weak version end anchor'
    Assert-CcodTrue (-not $assetContract.Contains("'^[0-9a-f]{64}$'")) 'release asset contract has no weak hash end anchor'
    Assert-CcodTrue (-not $assetContract.Contains("'^[0-9a-f]{40}$'")) 'release asset contract has no weak commit end anchor'
    Assert-CcodTrue (-not $draft.Contains("'^[0-9a-f]{64}$'")) 'draft command has no weak hash end anchor'
    Assert-CcodTrue (-not $draft.Contains("'^[0-9a-f]{40}$'")) 'draft command has no weak commit end anchor'
}

Invoke-CcodTask6Test 'task9-manual-acceptance-strict-parser' 'Promote rejects array-typed phases and newline-suffixed manual hashes' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseTask9StrictManual'
    $assetFixture = $null
    $evidence = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $evidence = Join-Path $assetFixture.Outside 'task9-strict-manual'
        $acceptanceDirectory = Join-Path $evidence 'acceptance'
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        $acceptancePath = Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'
        $record = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        $record.manualEvidence[0].phase = @('TrayEvidence')
        [IO.File]::WriteAllText($acceptancePath, (($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            &$module { param($Evidence,$Assets,$Tag,$Version,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version $Version -GitCommit $Commit } $evidence $assetFixture.Root 'v2.5.22' '2.5.22' $assetFixture.GitCommit | Out-Null
        } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        $record = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot (Get-CcodTask9EvidenceRoot)
        $record.manualEvidence[0].screenshotSha256 = ('1' * 64) + [char]10
        [IO.File]::WriteAllText($acceptancePath, (($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            &$module { param($Evidence,$Assets,$Tag,$Version,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version $Version -GitCommit $Commit } $evidence $assetFixture.Root 'v2.5.22' '2.5.22' $assetFixture.GitCommit | Out-Null
        } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'task9-promote-binds-manual-state' 'Promote rejects acceptance manual hashes that differ from the persisted Complete state' {
    $module = $null
    $assetFixture = $null
    $root = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $root = Join-Path $assetFixture.Outside 'task9-promote-manual-state'
        $acceptanceDirectory = Join-Path $root 'acceptance'
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        $record = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot $root
        $acceptancePath = Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'
        [IO.File]::WriteAllText($acceptancePath, (($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseTask9ManualState'
        $control=&$module {param($Evidence,$Assets,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit} $root $assetFixture.Root $assetFixture.GitCommit
        Assert-CcodEqual 'Complete' $control.phase 'complete persisted state and artifact control passes before mutation'
        $statePaths=@((Join-Path $root 'official-draft-acceptance\08-Complete.json'),(Join-Path $root 'official-draft-acceptance\manual-evidence\TrayEvidence-About.json'))
        $stateHashes=@($statePaths|ForEach-Object {Get-CcodTestFileSha256 $_})
        $screenshotPath=Join-Path $root 'official-draft-artifacts\About\screenshot.bin'
        [IO.File]::AppendAllText($screenshotPath,'replacement-reviewed-screenshot',[Text.UTF8Encoding]::new($false))
        $record.manualEvidence[0].screenshotSha256 = Get-CcodTestFileSha256 $screenshotPath
        Write-CcodTask5Json -Path $acceptancePath -Value $record
        Assert-CcodTrue (&$module {param($Root,$Manual) Assert-CcodGitHubDraftManualEvidenceArtifacts -EvidenceDirectory $Root -ManualEvidence $Manual} $root $record.manualEvidence) 'updated acceptance and artifact agree independently of the original persisted state'
        Assert-CcodThrows { &$module { param($Evidence,$Assets,$Tag,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version '2.5.22' -GitCommit $Commit } $root $assetFixture.Root 'v2.5.22' $assetFixture.GitCommit } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        $original=&$module {${function:Read-CcodGitHubDraftAcceptance}}
        try {
            &$module {
                param($Original)
                $body=$Original.ToString();$start=$body.IndexOf('$stateCompleteManual =');$end=$body.IndexOf('[void](Assert-CcodGitHubDraftManualEvidenceArtifacts', $start)
                if($start-lt0-or$end-le$start){throw 'manual-state mutant boundary missing'}
                Set-Item Function:script:Read-CcodGitHubDraftAcceptance -Value ([scriptblock]::Create($body.Remove($start,$end-$start)))
            } $original
            $mutant=&$module {param($Evidence,$Assets,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit} $root $assetFixture.Root $assetFixture.GitCommit
            Assert-CcodEqual 'Complete' $mutant.phase 'removing only persisted-state comparison admits the otherwise-valid negative'
        } finally {&$module {param($Original) Set-Item Function:script:Read-CcodGitHubDraftAcceptance -Value $Original} $original}
        for($index=0;$index-lt$statePaths.Count;$index++){Assert-CcodEqual $stateHashes[$index] (Get-CcodTestFileSha256 $statePaths[$index]) 'independent persisted state was never rewritten with the acceptance mutation'}
        Assert-CcodThrows {&$module {param($Evidence,$Assets,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit} $root $assetFixture.Root $assetFixture.GitCommit} 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'task9-promote-binds-all-assets' 'Promote rejects changed Setup bytes even when portable and manifest bytes are unchanged' {
    $module = $null
    $assetFixture = $null
    $root = $null
    try {
        $assetFixture = New-CcodTask5ExactAssetFixture
        $root = Join-Path $assetFixture.Outside 'task9-promote-all-assets'
        $acceptanceDirectory = Join-Path $root 'acceptance'
        [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
        $record = New-CcodTask9AcceptanceRecord -AssetFixture $assetFixture -EvidenceRoot $root
        $acceptancePath = Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'
        [IO.File]::WriteAllText($acceptancePath, (($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseTask9AllAssets'
        $control=&$module {param($Evidence,$Assets,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit} $root $assetFixture.Root $assetFixture.GitCommit
        Assert-CcodEqual 'Complete' $control.phase 'original complete candidate passes before changing Setup'
        $portableHash=Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $assetFixture.Names[4])
        $completePath=Join-Path $root 'official-draft-acceptance\08-Complete.json'
        $completeHash=Get-CcodTestFileSha256 $completePath
        [IO.File]::AppendAllText((Join-Path $assetFixture.Root $assetFixture.Names[5]), 'candidate-drift', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $assetFixture.Root $assetFixture.Names[6]),((Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $assetFixture.Names[5]))+' *'+$assetFixture.Names[5]),[Text.UTF8Encoding]::new($false))
        Sync-CcodTask5OuterAssetHash -Fixture $assetFixture -Distribution Setup -AssetName $assetFixture.Names[5]
        Sync-CcodTask5OuterAssetHash -Fixture $assetFixture -Distribution Setup -AssetName $assetFixture.Names[6]
        $contract=&$module {param($Root) Test-CcodExactReleaseAssetSet -AssetDirectory $Root -Version '2.5.22'} $assetFixture.Root
        Assert-CcodTrue $contract.Valid 'changed Setup fixture independently satisfies the complete asset contract'
        Assert-CcodThrows { &$module { param($Evidence,$Assets,$Tag,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag $Tag -Version '2.5.22' -GitCommit $Commit } $root $assetFixture.Root 'v2.5.22' $assetFixture.GitCommit } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        $original=&$module {${function:Read-CcodGitHubDraftAcceptance}}
        try {
            &$module {
                param($Original)
                $body=$Original.ToString();$start=$body.IndexOf('$currentAssets =');$end=$body.IndexOf('if ([string]$completeCandidate.version', $start)
                if($start-lt0-or$end-le$start){throw 'all-assets mutant boundary missing'}
                Set-Item Function:script:Read-CcodGitHubDraftAcceptance -Value ([scriptblock]::Create($body.Remove($start,$end-$start)))
            } $original
            $mutant=&$module {param($Evidence,$Assets,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit} $root $assetFixture.Root $assetFixture.GitCommit
            Assert-CcodEqual 'Complete' $mutant.phase 'removing only the persisted asset comparison admits a valid replacement candidate'
        } finally {&$module {param($Original) Set-Item Function:script:Read-CcodGitHubDraftAcceptance -Value $Original} $original}
        Assert-CcodEqual $portableHash (Get-CcodTestFileSha256 (Join-Path $assetFixture.Root $assetFixture.Names[4])) 'portable release identity was not changed'
        Assert-CcodEqual $completeHash (Get-CcodTestFileSha256 $completePath) 'original completed candidate was not rebound to new Setup bytes'
        Assert-CcodThrows {&$module {param($Evidence,$Assets,$Commit) Read-CcodGitHubDraftAcceptance -EvidenceDirectory $Evidence -AssetDirectory $Assets -Tag 'v2.5.22' -Version '2.5.22' -GitCommit $Commit} $root $assetFixture.Root $assetFixture.GitCommit} 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if ($null -ne $assetFixture) { Remove-CcodTask5ExactAssetFixture $assetFixture }
    }
}

Invoke-CcodTask6Test 'fix1-promote-requires-manual-artifacts' 'Promote rejects manual hashes without matching evidence artifacts' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftReleaseTask9ManualArtifacts'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-task9-manual-artifacts-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $manual = @(New-CcodTask9ManualEvidenceFixture -ManifestHash ('a' * 64) -Commit ('b' * 40))
        Assert-CcodThrows { &$module { param($Evidence,$Entries) Assert-CcodGitHubDraftManualEvidenceArtifacts -EvidenceDirectory $Evidence -ManualEvidence $Entries } $root $manual } 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-json-writer-rollback' 'Draft JSON writer removes a published destination when readback fails' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftJsonWriter'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-json-writer-' + [guid]::NewGuid().ToString('N'))
    $path = Join-Path $root 'verification.json'
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $record = [pscustomobject][ordered]@{ schemaVersion = 1; kind = 'fixture' }
        $control=Join-Path $root 'control.json'
        &$module {param($Path,$Value) Write-CcodGitHubDraftJsonCreateOnly -Path $Path -Record $Value -ErrorId 'CCOD_TEST_VERIFY_WRITE_FAILED' -ReadbackVerifier {param($Target) return $true} | Out-Null} $control $record
        Assert-CcodTrue ([IO.File]::Exists($control)) 'the same writer succeeds with a valid readback'
        $state=[pscustomobject]@{Calls=0;PublishedSeen=$false}
        $verifier = {param($Target) $state.Calls++;$state.PublishedSeen=[IO.File]::Exists($Target);return $false}.GetNewClosure()
        Assert-CcodThrows { &$module { param($Path,$Value,$Verifier) Write-CcodGitHubDraftJsonCreateOnly -Path $Path -Record $Value -ErrorId 'CCOD_TEST_VERIFY_WRITE_FAILED' -ReadbackVerifier $Verifier } $path $record $verifier } 'CCOD_TEST_VERIFY_WRITE_FAILED'
        Assert-CcodEqual 1 $state.Calls 'readback rejection is actually invoked'
        Assert-CcodTrue $state.PublishedSeen 'the callback leaves the published file for production cleanup'
        Assert-CcodTrue (-not [IO.File]::Exists($path)) 'failed draft JSON readback leaves no destination'
        Assert-CcodTrue ([IO.File]::Exists($control)) 'failed write cleanup preserves an unrelated existing receipt'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTask6Test 'fix1-json-writer-holds-directory-authority' 'Draft JSON writer holds the evidence directory while publishing and reading back' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftJsonWriterAuthority'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-json-authority-' + [guid]::NewGuid().ToString('N'))
    $moved = $root + '.moved'
    $path = Join-Path $root 'verification.json'
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $record = [pscustomobject][ordered]@{ schemaVersion = 1; kind = 'fixture' }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($record | ConvertTo-Json -Depth 8) + [Environment]::NewLine))
        $attack = [pscustomobject]@{ Succeeded = $false; Attempted = $false }
        $verifier = {
            param($Target)
            try {
                $replacement = [byte[]]$bytes.Clone()
                $directory = Split-Path -Parent $Target
                $attack.Attempted = $true
                Move-Item -LiteralPath $directory -Destination $moved -Force -ErrorAction Stop
                [IO.Directory]::CreateDirectory($directory) | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $directory ([IO.Path]::GetFileName($Target))), $replacement)
                $attack.Succeeded = $true
            } catch { $attack.Succeeded = $false }
            return $true
        }.GetNewClosure()
        &$module { param($Path,$Value,$Verifier) Write-CcodGitHubDraftJsonCreateOnly -Path $Path -Record $Value -ErrorId 'CCOD_TEST_VERIFY_WRITE_FAILED' -ReadbackVerifier $Verifier | Out-Null } $path $record $verifier
        Assert-CcodTrue $attack.Attempted 'the actual directory rename is attempted, not masked by an earlier file read failure'
        Assert-CcodTrue (-not $attack.Succeeded) 'held evidence directory authority blocks same-path replacement during readback'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        foreach ($directory in @($root,$moved)) { if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}

Invoke-CcodTask6Test 'fix1-json-reader-pins-parent-authority' 'Draft JSON reader rejects a junction parent instead of following pathname substitution' {
    $module = Import-CcodTask6ToolModule -Path (Join-Path $repositoryRoot 'tools/Invoke-GitHubDraftRelease.ps1') -Name 'CcodGitHubDraftJsonReaderAuthority'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-json-reader-' + [guid]::NewGuid().ToString('N'))
    $outside = Join-Path $root 'outside'
    $link = Join-Path $root 'link'
    try {
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'verification.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        Assert-CcodThrows {
            &$module { param($Path) Read-CcodGitHubDraftContractJson -Path $Path -ErrorId 'CCOD_TEST_PINNED_READ_INVALID' } (Join-Path $link 'verification.json') | Out-Null
        } 'CCOD_TEST_PINNED_READ_INVALID'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $link) {
            try { [IO.Directory]::Delete($link, $false) } catch { & cmd.exe /d /c rmdir /s /q $link | Out-Null }
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($script:CcodReleaseExecuted -le 0) { throw 'CCOD_RELEASE_TEST_SELECTION_INVALID: no tests executed.' }
if ($script:CcodReleaseFocus) {
    Write-Host "CCOD_RELEASE_FOCUSED_TESTS_PASSED case=$script:CcodReleaseFocus executed=$script:CcodReleaseExecuted skipped=$script:CcodReleaseSkipped"
} else {
    if ($script:CcodReleaseSkipped -ne 0) { throw 'CCOD_RELEASE_TEST_SELECTION_INVALID: full suite skipped tests.' }
    Write-Host "Release workflow self-tests passed: $script:CcodReleaseExecuted; skipped=0."
}
