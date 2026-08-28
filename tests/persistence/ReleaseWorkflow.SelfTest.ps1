$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$defenderPath = Join-Path $repositoryRoot 'tools\Test-ReleaseDefender.ps1'

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
    [IO.File]::WriteAllBytes($installer, [byte[]](9,8,7,6,5,4,3,2,1))
    $checksum = "$installer.sha256.txt"
    $installerHash = Get-CcodTestFileSha256 -Path $installer
    [IO.File]::WriteAllText($checksum, ("{0} *{1}`r`n" -f $installerHash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    $trayHost = Join-Path $root 'CodexRemote-fix-2.5.0-trayhost-provenance.json'
    [IO.File]::WriteAllText($trayHost, ('{"schemaVersion":1,"product":"CodexRemote-fix","version":"2.5.0","gitCommit":"' + ('a' * 40) + '","buildTimestampUtc":"2026-08-24T00:00:00.0000000Z"}'), [Text.UTF8Encoding]::new($false))
    $manifest = Join-Path $root 'CodexRemote-fix-2.5.0-setup-release-manifest.json'
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

Invoke-CcodTest 'production setup template has one inventory marker, no external includes, and derives every nested directory' {
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
        foreach ($relative in @('src','src\persistence','src\persistence\modules','payload','payload\2.5.22','payload\2.5.22\src','payload\2.5.22\src\persistence','payload\2.5.22\src\persistence\modules')) {
            Assert-CcodTrue ($inventory.Contains("Directories.Add('$relative');")) "generated setup inventory contains $relative"
        }
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
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'Install-CodexControlOtherDevices.ps1'),'exit 0',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'src\persistence\modules\InstallLifecycle.psm1'),'function Get-CcodLifecyclePayloadManifestFiles { @() }',[Text.UTF8Encoding]::new($false))
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

function Invoke-CcodInnoPayloadCompileFixture {
    param([switch]$IncludePayloadDefines,[switch]$OmitDestinationInventory)

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
    $arguments = @('/DProjectVersion=2.5.21',"/DTrayHostArtifactDirectory=$tray","/DPortableArtifactDirectory=$portable","/O$output\")
    if ($IncludePayloadDefines) {
        $arguments = @('/DProjectVersion=2.5.21',"/DTrayHostArtifactDirectory=$tray","/DPortableArtifactDirectory=$portable","/DInstallerPayloadDirectory=$payload","/DInstallerPayloadManifestSha256=$(Get-CcodTestFileSha256 -Path $manifestPath)")
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
    }
}

Invoke-CcodTest 'setup build and activation bind one immutable versioned payload end to end' {
    $build = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw -Encoding UTF8
    $inno = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activation = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -Raw -Encoding UTF8
    $installer = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Install-CodexControlOtherDevices.ps1') -Raw -Encoding UTF8

    Assert-CcodTrue ($build -cmatch 'New-InstallerPayloadManifest\.ps1' -and $build -cmatch 'New-InstallerDestinationInventory\.ps1' -and $build -cmatch 'InstallerPayloadManifestSha256' -and $build -cmatch 'New-CcodBuildGeneratedInnoScript') 'build invokes the tested generators and binds the inventory into generated setup compilation'
    Assert-CcodTrue ($inno -cmatch 'InstallerPayloadDirectory' -and $inno -cmatch 'DestDir:\s*"\{app\}\\payload\\\{#ProjectVersion\}"') 'Inno copies the immutable build payload into its exact version directory'
    Assert-CcodTrue ($inno -cmatch "ExpandConstant\('\{app\}\\payload\\\{#ProjectVersion\}'\)" -and $inno -cmatch '-ExpectedVersion\s+"\{#ProjectVersion\}') 'Inno binds activation to its compiled payload version'
    Assert-CcodTrue ($activation -cmatch '\[string\]\$ExpectedVersion' -and $activation -cmatch '\[string\]\$ExpectedPayloadManifestSha256' -and $activation -cmatch 'installer-payload\.manifest\.json') 'activation accepts and resolves the expected payload contract'
    Assert-CcodTrue ($installer -cmatch '\[string\]\$ExpectedVersion' -and $installer -cmatch '\[string\]\$PayloadManifestPath' -and $installer -cmatch '-ExpectedVersion\s+\$ExpectedVersion' -and $installer -cmatch '-PayloadManifestPath\s+\$PayloadManifestPath') 'installer forwards the immutable payload contract to lifecycle activation'
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
        Assert-CcodTrue ($compile.ExitCode -ne 0) 'setup compilation fails without an explicit installer payload directory and manifest hash'
        Assert-CcodTrue ($compile.Output -cmatch 'InstallerPayloadDirectory') 'compiler identifies the missing immutable payload define'
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
        Assert-CcodTrue ($compile.GeneratedSource -cmatch 'procedure AddCcodExpectedSetupDirectories' -and $compile.GeneratedSource -cmatch "Directories\.Add\('payload\\2\.5\.21'") 'compiler input contains the generated destination inventory procedure'
        Assert-CcodTrue ($compile.GeneratedSource -cnotmatch 'CCOD_INSTALLER_DESTINATION_INVENTORY' -and $compile.GeneratedSource -cnotmatch '(?m)^\s*#\s*(?:include\b|\+)') 'compiler input contains neither the marker nor an external include'
        Assert-CcodTrue (-not [IO.File]::Exists($compile.GeneratedPath)) 'payload compile cleans its generated compiler input'
        Assert-CcodTrue ($compile.Output -cmatch 'installer-payload\.manifest\.json' -and $compile.Output -cmatch 'payload\\package\.json') 'compiler input trace contains the payload manifest and manifest-listed file'
    } finally {
        if (Test-Path -LiteralPath $compile.Root) { Remove-Item -LiteralPath $compile.Root -Recurse -Force }
    }
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

Invoke-CcodTest 'Inno exposes a pre-write payload-directory reparse gate' {
    $inno = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $helper = [regex]::Match($inno,'(?ms)^function IsSafeExistingPayloadDirectory\(.*?^end;')
    Assert-CcodTrue $helper.Success 'production Inno script exposes the directory predicate used before payload writes'
    $treeHelper = [regex]::Match($inno,'(?ms)^function IsSafeExistingSetupTree\(.*?^end;')
    Assert-CcodTrue $treeHelper.Success 'production Inno script exposes a recursive destination-tree predicate'
    $inventoryValidator = [regex]::Match($inno,'(?ms)^function AreCcodExpectedSetupDirectoriesSafe\(.*?^end;')
    Assert-CcodTrue $inventoryValidator.Success 'production Inno script exposes a generated destination-inventory validator'
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
        $fileWriteMarker = Join-Path $expectedFileRoot 'payload-write-marker.txt'
        $junctionWriteMarker = Join-Path $expectedJunctionRoot 'payload-write-marker.txt'
        $resultPath = Join-Path $root 'result.txt'
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
  CCOD_INVALID_FILE_ATTRIBUTES = `$FFFFFFFF;
function GetFileAttributesW(const FileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';
$($helper.Value)
$($treeHelper.Value)
$inventorySource
$($inventoryValidator.Value)
function InitializeSetup(): Boolean;
begin
  if AreCcodExpectedSetupDirectoriesSafe('$($expectedFileRoot.Replace("'","''"))') then
    SaveStringToFile('$($fileWriteMarker.Replace("'","''"))','unsafe write',False);
  if AreCcodExpectedSetupDirectoriesSafe('$($expectedJunctionRoot.Replace("'","''"))') then
    SaveStringToFile('$($junctionWriteMarker.Replace("'","''"))','unsafe write',False);
  if IsSafeExistingPayloadDirectory('$($normal.Replace("'","''"))') and
     IsSafeExistingPayloadDirectory('$($missing.Replace("'","''"))') and
     (not IsSafeExistingPayloadDirectory('$($junction.Replace("'","''"))')) and
     (not IsSafeExistingSetupTree('$($tree.Replace("'","''"))')) and
     (not IsSafeExistingSetupTree('$($fileDirectory.Replace("'","''"))')) and
     AreCcodExpectedSetupDirectoriesSafe('$($normalExpectedRoot.Replace("'","''"))') and
     (not AreCcodExpectedSetupDirectoriesSafe('$($expectedFileRoot.Replace("'","''"))')) and
     (not AreCcodExpectedSetupDirectoriesSafe('$($expectedJunctionRoot.Replace("'","''"))')) then
    SaveStringToFile('$($resultPath.Replace("'","''"))','pass',False);
  Result := False;
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
    } finally {
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
    Assert-CcodTrue ($release -match 'New-GitHubReleaseNotes\.ps1') 'release publication uses the behavior-tested English notes extractor'
    Assert-CcodTrue ($release -match 'gh release download') 'existing release assets are downloaded before any publication decision'
    Assert-CcodTrue (-not ($release -match 'gh release upload[^\r\n]*--clobber')) 'release publication never overwrites an existing asset'
    Assert-CcodTrue ($release -match 'Read back published GitHub release assets') 'release publication re-downloads every uploaded asset for hash read-back'
    Assert-CcodTrue ($release -cmatch '(?ms)^permissions:\r?\n\s+contents: read\s*$') 'candidate build starts with read-only repository permission'
    Assert-CcodTrue ($release -cmatch '(?ms)^  publish:\r?\n    needs: build\r?\n    runs-on: windows-latest\r?\n    permissions:\r?\n      contents: write\s*$') 'only the publish job receives release-write permission'
}

$iss = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw; Assert-CcodTrue ($iss -match 'PortableArtifactDirectory' -and $iss -match 'CodexRemote.Portable.exe' -and $iss -match 'portable-launcher-provenance.json') 'Inno installer packages the portable launcher into the verified bin set';
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
        [IO.File]::WriteAllText($changelogPath,$fixture.Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false))
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
    Assert-CcodTrue ($readme.Contains('v2.5.22 is the current stable release')) 'English README marks v2.5.22 stable without a version-by-version What''s new block'
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
    Assert-CcodTrue ($readmeZh -match 'v2\.5\.22 \u662F\u5F53\u524D\u7A33\u5B9A\u7248') 'Chinese README marks v2.5.22 stable'
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

Write-Host 'Release workflow self-tests passed.'
