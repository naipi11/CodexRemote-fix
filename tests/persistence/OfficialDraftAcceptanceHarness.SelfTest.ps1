$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Restore-CcodTestDesktopModulePath
. (Join-Path $PSScriptRoot 'LegacyReleaseFixture.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'tests\installed\OfficialDraftAcceptance.psm1'
$wrapperPath = Join-Path $repositoryRoot 'tests\installed\Invoke-OfficialDraftAcceptance.ps1'

Invoke-CcodTest 'validation entrypoint includes the official draft acceptance harness' {
    $validationPath = Join-Path $repositoryRoot 'tests\Validate.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $validationPath -PathType Leaf) 'validation entrypoint exists'
    $validation = [IO.File]::ReadAllText($validationPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($validation.Contains('OfficialDraftAcceptanceHarness.SelfTest.ps1')) 'validation runs the official draft acceptance harness'
    Assert-CcodTrue ($validation.Contains('PSExecutionPolicyPreference')) 'acceptance validation clears inherited process policy for the child'
    Assert-CcodTrue ($validation.Contains('tests\installed\OfficialDraftAcceptance.psm1')) 'validation requires the official draft acceptance module'
}

Invoke-CcodTest 'legacy official manifest initial validation and persisted reload agree' {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-legacy-binding-'+[guid]::NewGuid().ToString('N'))
    $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $fixture=New-CcodLegacyReleaseFixture -Directory $root
        Assert-CcodEqual 8 @(Get-ChildItem -LiteralPath $root -File).Count 'fixture has the published legacy eight-file layout'
        $assetModule=&$module {Get-CcodOfficialDraftAssetModule}
        &$assetModule {param($Root)$path=Join-Path $Root 'CodexRemote-fix-2.5.21-release-manifest.json';$loaded=Read-CcodReleaseContractJson -Path $path -ErrorId 'LEGACY_FIXTURE';Test-CcodReleasePortableManifestDeep -Manifest $loaded.Value -ManifestRaw $loaded.Raw -ManifestPath $path -Directory $Root -Version '2.5.21' -ErrorId 'LEGACY_FIXTURE'|Out-Null} $root
        $validate=&$module {(Get-CcodOfficialDraftDefaultAdapters).ValidatePreviousSetup}
        $initial=&$validate $root '2.5.21'
        Assert-CcodTrue $initial.Valid 'real default adapter accepts the actual legacy manifest schema'
        Assert-CcodEqual $fixture.SetupSha256 $initial.InstallerSha256 'initial validation binds actual setup bytes'
        $previous=[pscustomobject][ordered]@{version='2.5.21';gitCommit=$initial.GitCommit;assetSha256=$initial.InstallerSha256;manifestSha256=$initial.ManifestSha256}
        Assert-CcodTrue (&$module {param($Value,$Root)Assert-CcodOfficialDraftPreviousSetupBinding -PreviousSetup $Value -PreviousAssetDirectory $Root} $previous $root) 'persisted binding accepts the same legacy contract'
        foreach($name in $fixture.Names){
            $path=Join-Path $root $name;$bytes=[IO.File]::ReadAllBytes($path)
            try {
                [IO.File]::WriteAllText($path,'tampered legacy asset',[Text.UTF8Encoding]::new($false))
                Assert-CcodThrows {&$validate $root '2.5.21'|Out-Null} 'CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID'
                Assert-CcodThrows {&$module {param($Value,$Root)Assert-CcodOfficialDraftPreviousSetupBinding -PreviousSetup $Value -PreviousAssetDirectory $Root} $previous $root|Out-Null} 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            } finally {[IO.File]::WriteAllBytes($path,$bytes)}
        }
        $extra=Join-Path $root 'extra.json'
        try {[IO.File]::WriteAllText($extra,'{}');Assert-CcodThrows {&$validate $root '2.5.21'|Out-Null} 'CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID'}finally{Remove-Item -LiteralPath $extra -Force}
        Assert-CcodTrue (&$validate $root '2.5.21').Valid 'all failed validations release handles and allow a valid retry'
    } finally {Remove-Module $module.Name -Force -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'validation acceptance child preserves the normal effective execution policy' {
    $validationPath = Join-Path $repositoryRoot 'tests\Validate.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$tokens, [ref]$parseErrors)
    Assert-CcodEqual 0 @($parseErrors).Count 'validation source parses before the real child invocation probe'
    $blocks = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.StartsWith('if (-not (Test-Path -LiteralPath $officialDraftAcceptanceSelfTest')
    }, $true))
    Assert-CcodEqual 1 $blocks.Count 'exactly one acceptance validation block is exercised'
    $markerFunctions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-CcodValidationSafeChildMarkers'
    }, $true))
    Assert-CcodEqual 1 $markerFunctions.Count 'the real validation marker classifier is available'
    $powershellExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source
    $hadPolicy = Test-Path -LiteralPath 'Env:PSExecutionPolicyPreference'
    $previousPolicy = $env:PSExecutionPolicyPreference
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-policy-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $probe = Join-Path $root 'policy-probe.ps1'
        [IO.File]::WriteAllText($probe, '[Console]::WriteLine("CCOD_POLICY_PROBE effective=" + (Get-ExecutionPolicy).ToString() + " process=" + (Get-ExecutionPolicy -Scope Process).ToString())', [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath 'Env:PSExecutionPolicyPreference' -ErrorAction SilentlyContinue
        $baseline = @(& $powershellExecutable -NoProfile -Command 'Get-ExecutionPolicy; Get-ExecutionPolicy -Scope Process')
        Assert-CcodEqual 0 $LASTEXITCODE 'normal child policy query succeeds without executing a script'
        Assert-CcodEqual 2 $baseline.Count 'normal child reports effective and process policies'
        Assert-CcodTrue ($baseline[0] -cmatch '^(Restricted|AllSigned|RemoteSigned|Unrestricted|Bypass)\z') 'baseline reports a supported effective policy'
        Assert-CcodEqual 'Undefined' $baseline[1] 'baseline has no explicit or inherited process policy'
        $normalPolicy = $baseline[0]
        $expectedMarker = 'CCOD_POLICY_PROBE effective={0} process={1}' -f $normalPolicy,$baseline[1]
        if ($hadPolicy) { $env:PSExecutionPolicyPreference = $previousPolicy }
        $observed = & {
            param($Probe, $ValidationBlock, $MarkerDefinition)
            . $MarkerDefinition
            $officialDraftAcceptanceSelfTest = $Probe
            $failures = [Collections.Generic.List[string]]::new()
            . $ValidationBlock
            [pscustomobject]@{
                ExitCode = $officialDraftAcceptanceExitCode
                Output = @($officialDraftAcceptanceOutput)
                Failures = @($failures.ToArray())
            }
        } $probe ([scriptblock]::Create($blocks[0].Extent.Text)) ([scriptblock]::Create($markerFunctions[0].Extent.Text))
        Assert-CcodEqual $hadPolicy (Test-Path -LiteralPath 'Env:PSExecutionPolicyPreference') 'validation restores parent process-policy presence'
        if ($hadPolicy) { Assert-CcodEqual $previousPolicy $env:PSExecutionPolicyPreference 'validation restores parent process-policy value' }
        if ($normalPolicy -in @('Restricted', 'AllSigned')) {
            Assert-CcodTrue ($observed.ExitCode -ne 0) 'normal policy still rejects the unsigned local probe'
            Assert-CcodEqual 1 $observed.Failures.Count 'normal policy rejection remains a validation failure'
            Assert-CcodTrue (-not (@($observed.Output | ForEach-Object { [string]$_ }) -contains $expectedMarker)) 'blocked probe never executes'
        } else {
            Assert-CcodEqual 0 $observed.ExitCode 'actual acceptance runner loads a local script allowed by the normal policy'
            Assert-CcodEqual 0 $observed.Failures.Count 'normal allowed execution has no validation failures'
            Assert-CcodEqual $expectedMarker ($observed.Output -join '') 'actual runner preserves normal effective and process policy'
        }
    } finally {
        if ($hadPolicy) { $env:PSExecutionPolicyPreference = $previousPolicy }
        else { Remove-Item -LiteralPath 'Env:PSExecutionPolicyPreference' -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

function Invoke-CcodAcceptancePrivate {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$PreviousAssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [string]$DraftId = '123',
        [hashtable]$Adapters,
        [string]$TrayOperation,
        [string]$RemoteOperation,
        [string]$ScreenshotPath,
        [string]$RedactedLogPath,
        [string]$ReviewState,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [switch]$AllowWindowsReboot
    )
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    try {
        return & $module {
            param($P, $A, $Previous, $Evidence, $Draft, $Tray, $Remote, $Screenshot, $Log, $Review, $Mutation, $Restart, $Reboot, $PrivateAdapters)
            Invoke-CcodOfficialDraftAcceptanceCore `
                -Phase $P `
                -AssetDirectory $A `
                -PreviousAssetDirectory $Previous `
                -EvidenceRoot $Evidence `
                -DraftId $Draft `
                -TrayOperation $Tray `
                -RemoteOperation $Remote `
                -ScreenshotPath $Screenshot `
                -RedactedLogPath $Log `
                -ReviewState $Review `
                -AllowMachineMutation:$Mutation `
                -AllowCodexRestart:$Restart `
                -AllowWindowsReboot:$Reboot `
                -Adapters $PrivateAdapters
        } $Phase $AssetDirectory $PreviousAssetDirectory $EvidenceRoot $DraftId $TrayOperation $RemoteOperation $ScreenshotPath $RedactedLogPath $ReviewState $AllowMachineMutation $AllowCodexRestart $AllowWindowsReboot $Adapters
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
    }
}

function New-CcodAcceptanceCandidateFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-candidate-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $version = '2.5.22'
    $commit = 'c' * 40
    $names = @(
        "CodexRemote-fix-$version-windows-x64.zip",
        "CodexRemote-fix-$version-windows-x64.zip.sha256.txt",
        "CodexRemote-fix-$version-trayhost-provenance.json",
        "CodexRemote-fix-$version-payload-manifest.json",
        "CodexRemote-fix-$version-release-manifest.json",
        "CodexRemote-fix-$version-setup.exe",
        "CodexRemote-fix-$version-setup.exe.sha256.txt",
        "CodexRemote-fix-$version-setup-provenance.json",
        "CodexRemote-fix-$version-setup-payload-manifest.json",
        "CodexRemote-fix-$version-setup-destination-inventory.iss",
        "CodexRemote-fix-$version-setup-release-manifest.json"
    )
    foreach ($name in $names) {
        [IO.File]::WriteAllBytes((Join-Path $root $name), [Text.Encoding]::UTF8.GetBytes("fixture:$name"))
    }
    $assets = @($names | ForEach-Object {
        [pscustomobject][ordered]@{ name = $_; sha256 = Get-CcodTestFileSha256 -Path (Join-Path $root $_) }
    })
    return [pscustomobject][ordered]@{
        Root = $root
        Version = $version
        GitCommit = $commit
        Names = $names
        Contract = [pscustomobject][ordered]@{
            Valid = $true
            Version = $version
            GitCommit = $commit
            Assets = $assets
            SetupManifestSha256 = $assets[10].sha256
            PortableManifestSha256 = $assets[4].sha256
        }
    }
}

function New-CcodAcceptanceDefenderReceipt {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][ValidateSet('Setup','PortableZip')][string]$AssetType
    )
    $setup = $AssetType -ceq 'Setup'
    $assetName = if ($setup) { $Fixture.Names[5] } else { $Fixture.Names[0] }
    $checksumName = if ($setup) { $Fixture.Names[6] } else { $Fixture.Names[1] }
    $manifestName = if ($setup) { $Fixture.Names[10] } else { $Fixture.Names[4] }
    $assetHash = [string](($Fixture.Contract.Assets | Where-Object { $_.name -ceq $assetName }).sha256)
    $checksumHash = [string](($Fixture.Contract.Assets | Where-Object { $_.name -ceq $checksumName }).sha256)
    $manifestHash = [string](($Fixture.Contract.Assets | Where-Object { $_.name -ceq $manifestName }).sha256)
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        assetType = $AssetType
        assetName = $assetName
        assetSha256 = $assetHash
        checksumName = $checksumName
        checksumSha256 = $checksumHash
        manifestName = $manifestName
        manifestSha256 = $manifestHash
        version = $Fixture.Version
        gitCommit = $Fixture.GitCommit
        origin = 'InternetDownload'
        workflowArtifactIdentity = $null
        zoneId = 3
        defenderServiceEnabled = $true
        antivirusEnabled = $true
        realTimeProtectionEnabled = $true
        defenderPlatformVersion = '4.18.26070.1'
        defenderEngineVersion = '1.1.26070.1'
        signatureVersion = '1.999.1.0'
        signatureUpdatedAtUtc = '2030-02-03T02:05:06.0000000Z'
        scanStartedAtUtc = '2030-02-03T04:05:06.0000000Z'
        scanCompletedAtUtc = '2030-02-03T04:05:07.0000000Z'
        detectionCount = 0
        outcome = 'Completed'
        errorCode = $null
    }
}

function New-CcodAcceptanceFacts {
    param(
        [switch]$Absent,
        [string]$KeyHash = ('b' * 64),
        [string]$BootId = 'boot-1',
        [string]$RuntimeId = 'runtime-2.5.22',
        [UInt64]$Generation = 2,
        [string]$Version = '2.5.22'
    )
    if ($Absent) {
        return [pscustomobject][ordered]@{
            installRootPresent = $false; appRootPresent = $false; runtimeRootPresent = $false; activePointerPresent = $false
            activeRuntimeId = $null; activeGeneration = $null; runtimeManifestSha256 = $null
            supervisor = @(); trayHost = @(); trayHostIdentity = $null; trayAuthenticated = $false; codex = @()
            taskState = 'Absent'; statusPhase = 'Unavailable'; statusRuntimeId = $null; statusCodex = $null; codexCount = 0
            transitionStage = 'Idle'; lifecycleReceipt = $null
            debugPorts = @()
            shortcuts = [pscustomobject][ordered]@{ startMenu = $false; desktop = $false }
            debugEndpoints = @(); protectionReady = $false; protectionRecovered = $false
            deviceKeyPresent = $true; deviceKeySha256 = $KeyHash; bootId = $BootId
            privatePath = 'C:\\Users\\fixture\\private'; token = 'fixture-token'; rawLog = 'fixture raw log'
        }
    }
    return [pscustomobject][ordered]@{
        installRootPresent = $true; appRootPresent = $true; runtimeRootPresent = $true; activePointerPresent = $true; installReady = $true
        activeRuntimeId = $RuntimeId; activeGeneration = $Generation; runtimeManifestSha256 = ('d' * 64)
        supervisor = @([pscustomobject]@{ pid = 200; creationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
        trayHost = @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
        trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }
        trayAuthenticated = $true; codex = @([pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }); codexCount = 1
        taskState = 'Ready'; statusPhase = 'Active'; statusRuntimeId = $RuntimeId; aboutVersion = $Version
        statusCodex = [pscustomobject][ordered]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
        transitionStage = 'Idle'
        lifecycleReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = $RuntimeId; runtimeGeneration = $Generation; phase = 'Completed' }
        shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
        debugEndpoints = @(
            [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
        )
        debugPorts = @(9229,9230)
        protectionReady = $true; protectionRecovered = $true
        deviceKeyPresent = $true; deviceKeySha256 = $KeyHash; bootId = $BootId
        privatePath = 'C:\\Users\\fixture\\private'; token = 'fixture-token'; rawLog = 'fixture raw log'
    }
}

function New-CcodAcceptanceRawFacts {
    param([switch]$Absent)
    $facts = New-CcodAcceptanceFacts -Absent:$Absent
    $facts | Add-Member -NotePropertyName appPresent -NotePropertyValue ([bool]$facts.appRootPresent)
    if ($Absent) { $facts | Add-Member -NotePropertyName aboutVersion -NotePropertyValue $null }
    $facts.PSObject.Properties.Remove('appRootPresent')
    $facts.PSObject.Properties.Remove('codexCount')
    foreach ($name in @('supervisor','trayHost','codex')) {
        $facts.$name = @($facts.$name | ForEach-Object { [pscustomobject]@{ Pid = [uint32]$_.pid; CreationTimeUtc = [string]$_.creationTimeUtc } })
    }
    if ($null -ne $facts.statusCodex) { $facts.statusCodex = [pscustomobject]@{ Pid = [uint32]$facts.statusCodex.pid; CreationTimeUtc = [string]$facts.statusCodex.creationTimeUtc } }
    return $facts
}

function New-CcodAcceptancePhaseAdapters {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)]$State,
        [switch]$ReturnAbsentAfterUninstall,
        [switch]$LeaveInstallRootAfterUninstall
    )
    $previousContractPath=Join-Path $repositoryRoot 'tests/installed/OfficialDraftAcceptance.psm1'
    $previousFixtureWriter=${function:New-CcodLegacyReleaseFixture}
    return @{
        ValidateAssetSet = {
            param($Path, $Version)
            return $Fixture.Contract
        }.GetNewClosure()
        ValidatePreviousSetup = {
            param($Path, $Version)
            if ($null -ne $State.PreviousCalls) { $State.PreviousCalls++ }
            try {
                if ($Version -cne '2.5.21') { throw 'previous version request' }
                $directory = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                if ($directory -isnot [IO.DirectoryInfo] -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'previous directory' }
                $setupPath = Join-Path $directory.FullName 'CodexRemote-fix-2.5.21-setup.exe'
                $manifestPath = Join-Path $directory.FullName 'CodexRemote-fix-2.5.21-setup-release-manifest.json'
                $seed = $true
                if ($null -ne $State.PSObject.Properties['SeedPreviousSetup']) {
                    if ($State.SeedPreviousSetup -isnot [bool]) { throw 'seed flag' }
                    $seed = [bool]$State.SeedPreviousSetup
                }
                if ($seed -and -not [IO.File]::Exists($setupPath) -and -not [IO.File]::Exists($manifestPath)) {
                    &$previousFixtureWriter -Directory $directory.FullName|Out-Null
                }
                $previousModule=Import-Module $previousContractPath -PassThru -DisableNameChecking
                return &$previousModule {param($Root,$Version)Get-CcodOfficialDraftPreviousSetupContract -Directory $Root -Version $Version} $directory.FullName $Version
            } catch { throw 'previous setup fixture validation failed' }
        }.GetNewClosure()
        GetDraftIdentity = {
            param($Path, $Candidate, $ExpectedDraftId)
            return [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = [string]$ExpectedDraftId }
        }.GetNewClosure()
        InvokeDefenderCheck = {
            param($Path, $AssetType, $Origin, $Version, $GitCommit, $EvidencePath)
            $State.DefenderCalls.Add(('{0}:{1}' -f $AssetType, $Origin))
            return New-CcodAcceptanceDefenderReceipt -Fixture $Fixture -AssetType $AssetType
        }.GetNewClosure()
        CaptureFacts = {
            param($Context, $Point)
            $State.CaptureCalls.Add(('{0}:{1}' -f $Context.phase, $Point))
            if ($null -ne $State.PSObject.Properties['Events']) { $State.Events.Add(('Capture:{0}:{1}' -f $Context.phase, $Point)) }
            if ($Context.phase -ceq 'Uninstall' -and $Point -ceq 'After' -and $ReturnAbsentAfterUninstall) {
                $absentFacts = New-CcodAcceptanceFacts -Absent -KeyHash $State.KeyHash -BootId $State.BootId
                if ($LeaveInstallRootAfterUninstall) { $absentFacts.installRootPresent = $true }
                return $absentFacts
            }
            if ($Context.phase -ceq 'LegacyUpgrade' -and $Point -ceq 'Before') {
                return New-CcodAcceptanceFacts -RuntimeId '2.5.21-legacy-runtime' -Generation 1 -Version '2.5.21' -KeyHash $State.KeyHash -BootId $State.BootId
            }
            return $State.Facts
        }.GetNewClosure()
        RunPhase = {
            param($Context)
            $State.RunCalls.Add([string]$Context.phase)
            if ($null -ne $State.PSObject.Properties['Events']) { $State.Events.Add(('Run:{0}' -f $Context.phase)) }
            $setupName = [IO.Path]::GetFileName([string]$Context.setupPath)
            $setupAsset = @($Fixture.Contract.Assets | Where-Object { $_.name -ceq $setupName })
            [pscustomobject][ordered]@{ completed = $true; outcome = 'Completed'; installerSha256 = [string]$setupAsset[0].sha256; runtimeManifestSha256 = [string]$State.Facts.runtimeManifestSha256 }
        }.GetNewClosure()
        RunManualOperation = {
            param($Context,$Operation)
            $states = @{ About = 'AboutVisible'; Language = 'LanguageChanged'; OpenLogs = 'LogsOpened'; Repair = 'RepairCompleted'; SecondDeviceControl = 'SecondDeviceControlled' }
            $codes = @{ About = 'CCOD_TRAYABOUT_COMPLETED'; Language = 'CCOD_TRAYLANGUAGE_COMPLETED'; OpenLogs = 'CCOD_TRAYOPENLOGS_COMPLETED'; Repair = 'CCOD_TRAYREPAIR_COMPLETED'; SecondDeviceControl = 'CCOD_SECONDDEVICE_COMPLETED' }
            $timestamp = '2030-02-03T04:05:06.0000000Z'
            $proof = $null
            if ([string]$Operation -ceq 'SecondDeviceControl') {
                $proof = [pscustomobject][ordered]@{ schemaVersion = 1; timestampUtc = $timestamp; kind = 'remote-control-manual-proof'; operation = 'SecondDeviceControl'; deviceRole = 'SecondDevice'; challenge = [string]$Context.manualChallenge; candidateVersion = [string]$Context.expectedVersion; runtimeId = [string]$State.Facts.activeRuntimeId; runtimeGeneration = [UInt64]$State.Facts.activeGeneration; runtimeManifestSha256 = [string]$State.Facts.runtimeManifestSha256; attestation = 'HumanReviewedStructuredAttestation'; connection = 'Connected'; control = 'Completed'; outcome = 'Completed'; code = 'CCOD_REMOTE_ACTION_COMPLETED' }
            } else {
                $commands = @{ About = 'ShowAbout'; Language = 'SetLanguageEnglish'; OpenLogs = 'OpenLogs'; Repair = 'CheckAndRepair' }
                $proof = [pscustomobject][ordered]@{ timestampUtc = $timestamp; command = [string]$commands[$Operation]; revision = [UInt64]1; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }
            }
            return [pscustomobject][ordered]@{ verified = $true; operation = [string]$Operation; terminalState = [string]$states[$Operation]; code = [string]$codes[$Operation]; proof = $proof; screenshotSha256 = Get-CcodTestFileSha256 -Path $Context.screenshotPath; redactedLogSha256 = Get-CcodTestFileSha256 -Path $Context.redactedLogPath }
        }.GetNewClosure()
        GetBootIdentity = {
            $State.BootCalls++
            return [string]$State.BootId
        }.GetNewClosure()
        Reboot = {
            $State.RebootCalls++
            return $true
        }.GetNewClosure()
        GetUtcNow = {
            return [datetime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()
        }.GetNewClosure()
    }
}

function Invoke-CcodAcceptanceThroughReady {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)]$PreviousRoot,
        [Parameter(Mandatory)]$EvidenceRoot,
        [Parameter(Mandatory)]$Adapters,
        [Parameter(Mandatory)]$State
    )
    Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters | Out-Null
    Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
    Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
    Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
    Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
    $State.BootId = 'boot-2'
    $State.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
    Invoke-CcodAcceptancePrivate -Phase PostReboot -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
    Invoke-CcodAcceptancePrivate -Phase ReadyForManualEvidence -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters | Out-Null
}

function New-CcodAcceptanceManualInputFiles {
    param([Parameter(Mandatory)][string]$Root)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $paths = @{}
    foreach ($operation in @('About','Language','OpenLogs','Repair','SecondDeviceControl')) {
        $paths[$operation] = [pscustomobject][ordered]@{
            Screenshot = Join-Path $Root ($operation + '-screenshot.png')
            Log = Join-Path $Root ($operation + '-redacted.log')
        }
        [IO.File]::WriteAllText($paths[$operation].Screenshot, 'screenshot-' + $operation, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($paths[$operation].Log, 'redacted-log-' + $operation, [Text.UTF8Encoding]::new($false))
    }
    return $paths
}

function Invoke-CcodAcceptanceManualRecords {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)]$PreviousRoot,
        [Parameter(Mandatory)]$EvidenceRoot,
        [Parameter(Mandatory)]$Adapters,
        [Parameter(Mandatory)]$Paths
    )
    foreach ($operation in @('About','Language','OpenLogs','Repair')) {
        Invoke-CcodAcceptancePrivate -Phase TrayEvidence -TrayOperation $operation -ScreenshotPath $Paths[$operation].Screenshot -RedactedLogPath $Paths[$operation].Log -ReviewState Reviewed -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters | Out-Null
    }
    Invoke-CcodAcceptancePrivate -Phase RemoteEvidence -RemoteOperation SecondDeviceControl -ScreenshotPath $Paths.SecondDeviceControl.Screenshot -RedactedLogPath $Paths.SecondDeviceControl.Log -ReviewState Reviewed -AssetDirectory $Fixture.Root -PreviousAssetDirectory $PreviousRoot -EvidenceRoot $EvidenceRoot -Adapters $Adapters | Out-Null
}

try {
    Invoke-CcodTest 'official draft acceptance exposes the required public module and wrapper boundary' {
        Assert-CcodTrue (Test-Path -LiteralPath $modulePath -PathType Leaf) 'official-draft acceptance module exists'
        Assert-CcodTrue (Test-Path -LiteralPath $wrapperPath -PathType Leaf) 'official-draft acceptance wrapper exists'
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodEqual 'Invoke-CcodOfficialDraftAcceptance' ((@($module.ExportedCommands.Keys | Sort-Object) -join ',')) 'module exports only the official-draft acceptance command'
            $command = Get-Command Invoke-CcodOfficialDraftAcceptance -Module $module.Name -ErrorAction Stop
            Assert-CcodTrue (-not $command.Parameters.ContainsKey('Adapters')) 'public command does not expose test adapters'
            Assert-CcodTrue ($command.Parameters.ContainsKey('Phase')) 'public command exposes phase'
            Assert-CcodTrue ($command.Parameters.ContainsKey('AssetDirectory')) 'public command exposes candidate asset directory'
            Assert-CcodTrue ($command.Parameters.ContainsKey('PreviousAssetDirectory')) 'public command exposes previous asset directory'
            Assert-CcodTrue ($command.Parameters.ContainsKey('EvidenceRoot')) 'public command exposes evidence root'
            Assert-CcodTrue ($command.Parameters.ContainsKey('DraftId')) 'public command exposes the official draft identifier'
            Assert-CcodTrue ($command.Parameters.ContainsKey('AllowMachineMutation')) 'public command exposes machine mutation authorization'
            Assert-CcodTrue ($command.Parameters.ContainsKey('AllowCodexRestart')) 'public command exposes Codex restart authorization'
            Assert-CcodTrue ($command.Parameters.ContainsKey('AllowWindowsReboot')) 'public command exposes Windows reboot authorization'
            Assert-CcodTrue ($command.Parameters.ContainsKey('TrayOperation')) 'public command exposes bounded tray operation'
            Assert-CcodTrue ($command.Parameters.ContainsKey('RemoteOperation')) 'public command exposes bounded remote operation'
            Assert-CcodTrue ($command.Parameters.ContainsKey('ScreenshotPath')) 'public command exposes screenshot evidence path'
            Assert-CcodTrue ($command.Parameters.ContainsKey('RedactedLogPath')) 'public command exposes redacted log evidence path'
            Assert-CcodTrue ($command.Parameters.ContainsKey('ReviewState')) 'public command exposes manual evidence review state'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft acceptance rejects a missing evidence root before adapter work' {
        $assetRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-assets-' + [guid]::NewGuid().ToString('N'))
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-missing-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.Directory]::CreateDirectory($assetRoot) | Out-Null
            [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $assetRoot -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot
            } 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID'
        } finally {
            foreach ($path in @($assetRoot, $previousRoot, $evidenceRoot)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
        }
    }

    Invoke-CcodTest 'official draft public wrapper runs in a fresh process and fails closed' {
        $assetRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-wrapper-assets-' + [guid]::NewGuid().ToString('N'))
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-wrapper-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-wrapper-missing-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($assetRoot) | Out-Null
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        try {
            $stderrPath = Join-Path $assetRoot 'wrapper.stderr.log'
            $stdoutPath = Join-Path $assetRoot 'wrapper.stdout.log'
            $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-File',$wrapperPath,'-Phase','Preflight','-AssetDirectory',$assetRoot,'-PreviousAssetDirectory',$previousRoot,'-EvidenceRoot',$evidenceRoot) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru -WindowStyle Hidden
            $exitCode = $child.ExitCode
            $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [IO.File]::ReadAllText($stdoutPath, [Text.UTF8Encoding]::new($false, $true)) } else { '' }
            $stderrBytes = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [IO.File]::ReadAllBytes($stderrPath) } else { [byte[]]@() }
            $stderr = ([Text.Encoding]::ASCII.GetString($stderrBytes) + "`n" + [Text.Encoding]::Unicode.GetString($stderrBytes))
            $joined = $stdout + "`n" + $stderr
            Assert-CcodEqual 1 $exitCode 'public wrapper exits nonzero for a missing evidence root'
            Assert-CcodTrue ($joined.Contains('CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID')) 'public wrapper preserves the stable fail-closed error code'
            $invalidStderrPath = Join-Path $assetRoot 'wrapper-invalid-phase.stderr.log'
            $invalidStdoutPath = Join-Path $assetRoot 'wrapper-invalid-phase.stdout.log'
            $invalidChild = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-File',$wrapperPath,'-Phase','NotARealPhase','-AssetDirectory',$assetRoot,'-PreviousAssetDirectory',$previousRoot,'-EvidenceRoot',$evidenceRoot) -RedirectStandardOutput $invalidStdoutPath -RedirectStandardError $invalidStderrPath -Wait -PassThru -WindowStyle Hidden
            $invalidBytes = if (Test-Path -LiteralPath $invalidStderrPath -PathType Leaf) { [IO.File]::ReadAllBytes($invalidStderrPath) } else { [byte[]]@() }
            $invalidOutput = ([Text.Encoding]::ASCII.GetString($invalidBytes) + "`n" + [Text.Encoding]::Unicode.GetString($invalidBytes))
            Assert-CcodEqual 1 $invalidChild.ExitCode 'public wrapper exits nonzero for an invalid phase'
            Assert-CcodTrue ($invalidOutput.Contains('CCOD_ACCEPTANCE_PHASE_INVALID')) 'public wrapper converts binder-level phase rejection into a stable error code'
        } finally {
            foreach ($path in @($assetRoot, $previousRoot, $evidenceRoot)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Invoke-CcodTest 'official draft preflight scans exactly two downloaded assets and persists a bound receipt' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $calls = [Collections.Generic.List[string]]::new()
        $defenderArguments = [Collections.Generic.List[object]]::new()
        try {
            $adapters = @{
                ValidateAssetSet = {
                    param($Path, $Version)
                    $calls.Add(('ValidateAssetSet:{0}:{1}' -f $Path, $Version))
                    return $fixture.Contract
                }.GetNewClosure()
                GetDraftIdentity = {
                    param($Path, $Candidate)
                    $calls.Add('GetDraftIdentity')
                    return [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = '123' }
                }.GetNewClosure()
                InvokeDefenderCheck = {
                    param($Path, $AssetType, $Origin, $Version, $GitCommit, $EvidencePath)
                    $calls.Add(('Defender:{0}:{1}' -f $AssetType, $Origin))
                    $assetIndex = if ($AssetType -ceq 'Setup') { 5 } else { 0 }
                    $defenderArguments.Add([pscustomobject][ordered]@{
                        AssetType = $AssetType
                        Origin = $Origin
                        Version = $Version
                        GitCommit = $GitCommit
                        CandidatePath = [IO.Path]::GetFullPath((Join-Path $Path $fixture.Names[$assetIndex]))
                        EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
                    })
                    return New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType $AssetType
                }.GetNewClosure()
                GetUtcNow = {
                    return [datetime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()
                }.GetNewClosure()
            }
            $result = Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            Assert-CcodEqual 'Preflight' ([string]$result.phase) 'preflight returns its canonical phase'
            Assert-CcodEqual 'Completed' ([string]$result.outcome) 'preflight returns a completed outcome'
            $defenderCalls = @($calls | Where-Object { $_ -like 'Defender:*' })
            Assert-CcodEqual 2 $defenderCalls.Count 'preflight invokes Defender exactly twice'
            Assert-CcodEqual 'Defender:Setup:InternetDownload' $defenderCalls[0] 'Setup is scanned first as an InternetDownload'
            Assert-CcodEqual 'Defender:PortableZip:InternetDownload' $defenderCalls[1] 'portable ZIP is scanned second as an InternetDownload'
            $stateDirectory = Join-Path $evidenceRoot 'official-draft-acceptance'
            $expectedAssetIndexes = @(5,0)
            for ($index = 0; $index -lt 2; $index++) {
                $arguments = $defenderArguments[$index]
                Assert-CcodEqual @('Setup','PortableZip')[$index] ([string]$arguments.AssetType) 'Defender callback receives the ordered asset type'
                Assert-CcodEqual 'InternetDownload' ([string]$arguments.Origin) 'Defender callback receives the download origin'
                Assert-CcodEqual $fixture.Version ([string]$arguments.Version) 'Defender callback receives the candidate version'
                Assert-CcodEqual $fixture.Contract.GitCommit ([string]$arguments.GitCommit) 'Defender callback receives the candidate commit'
                Assert-CcodEqual ([IO.Path]::GetFullPath((Join-Path $fixture.Root $fixture.Names[$expectedAssetIndexes[$index]]))) ([string]$arguments.CandidatePath) 'Defender callback receives the expected candidate asset'
                Assert-CcodTrue (([string]$arguments.EvidencePath).StartsWith([IO.Path]::GetFullPath($stateDirectory) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Defender callback evidence is inside the acceptance state directory'
                Assert-CcodTrue ([IO.Path]::GetFileName([string]$arguments.EvidencePath) -cmatch '^\.defender-(Setup|PortableZip)-[0-9a-f]{32}\.json$') 'Defender callback evidence uses a bounded pending receipt name'
            }
            $preflightPath = Join-Path $stateDirectory '01-Preflight.json'
            Assert-CcodTrue (Test-Path -LiteralPath $preflightPath -PathType Leaf) 'preflight writes one durable state receipt'
            $serialized = [IO.File]::ReadAllText($preflightPath)
            foreach ($forbidden in @('C:\\Users', 'private', 'token', 'account', 'raw log')) {
                Assert-CcodTrue (-not $serialized.Contains($forbidden)) "preflight receipt omits $forbidden data"
            }
            $receipt = $serialized | ConvertFrom-Json
            Assert-CcodEqual 'Preflight' ([string]$receipt.phase) 'durable receipt records the exact phase'
            Assert-CcodEqual 'v2.5.22' ([string]$receipt.draft.tag) 'durable receipt records the draft tag'
            Assert-CcodEqual '123' ([string]$receipt.draft.id) 'durable receipt records the bounded draft id'
            Assert-CcodEqual 2 @($receipt.facts.defenderReceipts).Count 'durable receipt retains both Defender receipts'
            for ($index = 0; $index -lt 2; $index++) {
                $assetName = $fixture.Names[$expectedAssetIndexes[$index]]
                $expectedHash = [string](($fixture.Contract.Assets | Where-Object { $_.name -ceq $assetName }).sha256)
                Assert-CcodEqual $assetName ([string]$receipt.facts.defenderReceipts[$index].assetName) 'durable Defender receipts preserve asset order'
                Assert-CcodEqual $expectedHash ([string]$receipt.facts.defenderReceipts[$index].assetSha256) 'durable Defender receipts bind exact asset hashes'
            }
        } finally {
            foreach ($path in @($fixture.Root, $previousRoot)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
        }
    }

    Invoke-CcodTest 'official draft rejects a missing draft identifier before Defender work' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $calls = [Collections.Generic.List[string]]::new()
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        try {
            $adapters = @{
                ValidateAssetSet = { param($Path,$Version) $fixture.Contract }.GetNewClosure()
                GetDraftIdentity = { param($Path,$Candidate) [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = $null } }.GetNewClosure()
                InvokeDefenderCheck = { param($Path,$AssetType,$Origin,$Version,$GitCommit,$EvidencePath) $calls.Add($AssetType); New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType $AssetType }.GetNewClosure()
            }
            Assert-CcodThrows { Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null } 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_INVALID'
            Assert-CcodEqual 0 $calls.Count 'missing draft ID blocks Defender work'
            $adapters.GetDraftIdentity = { param($Path,$Candidate,$Expected) [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = 'draft-123' } }.GetNewClosure()
            Assert-CcodThrows { Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null } 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_INVALID'
            Assert-CcodEqual 0 $calls.Count 'nonnumeric draft ID also blocks Defender work'
        } finally {
            foreach ($path in @($fixture.Root,$previousRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
        }
    }

    Invoke-CcodTest 'official draft acceptance enforces authorization before machine mutation and rejects skipped phases' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0
            RebootCalls = 0
            PreviousCalls = 0
            BootId = 'boot-1'
            KeyHash = ('b' * 64)
            Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            } 'CCOD_ACCEPTANCE_MACHINE_MUTATION_NOT_ALLOWED'
            Assert-CcodEqual 0 $state.RunCalls.Count 'missing machine authorization precedes the operation adapter'
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation
            } 'CCOD_ACCEPTANCE_CODEX_RESTART_NOT_ALLOWED'
            Assert-CcodEqual 0 $state.RunCalls.Count 'missing restart authorization also precedes the operation adapter'
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart
            } 'CCOD_ACCEPTANCE_PHASE_ORDER_INVALID'
            Assert-CcodEqual 0 $state.RunCalls.Count 'a skipped phase cannot invoke machine mutation'
        } finally {
            foreach ($path in @($fixture.Root, $previousRoot)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
        }
    }

    Invoke-CcodTest 'official draft legacy upgrade requires the public v2.5.21 Setup and preserves the device key hash' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            Events = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            $previous = @(& $adapters.ValidatePreviousSetup $previousRoot '2.5.21')
            Assert-CcodEqual 1 $previous.Count 'legacy setup validator returns one real previous setup record'
            $previousSetupPath = Join-Path $previousRoot 'CodexRemote-fix-2.5.21-setup.exe'
            $previousManifestPath = Join-Path $previousRoot 'CodexRemote-fix-2.5.21-setup-release-manifest.json'
            Assert-CcodTrue ([IO.File]::Exists($previousSetupPath) -and [IO.File]::Exists($previousManifestPath)) 'legacy setup validator binds both previous files on disk'
            Assert-CcodEqual (Get-CcodTestFileSha256 -Path $previousSetupPath) ([string]$previous[0].InstallerSha256) 'legacy setup metadata binds the actual installer hash'
            Assert-CcodEqual (Get-CcodTestFileSha256 -Path $previousManifestPath) ([string]$previous[0].ManifestSha256) 'legacy setup metadata binds the actual manifest hash'
            $originalPreviousManifest = [IO.File]::ReadAllBytes($previousManifestPath)
            $tamperedPreviousManifest = [IO.File]::ReadAllText($previousManifestPath) | ConvertFrom-Json
            $tamperedPreviousManifest.version = '2.5.22'
            [IO.File]::WriteAllText($previousManifestPath, ($tamperedPreviousManifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $rejectedVersion = $false
            try { & $adapters.ValidatePreviousSetup $previousRoot '2.5.21' | Out-Null } catch { $rejectedVersion = $true }
            Assert-CcodTrue $rejectedVersion 'legacy setup validator rejects a manifest version detached from the requested v2.5.21'
            [IO.File]::WriteAllBytes($previousManifestPath, $originalPreviousManifest)
            $wrongPreviousRoot = Join-Path $fixture.Root 'wrong-previous-root'
            [IO.Directory]::CreateDirectory($wrongPreviousRoot) | Out-Null
            $state | Add-Member -NotePropertyName SeedPreviousSetup -NotePropertyValue $false
            $rejectedPath = $false
            try { & $adapters.ValidatePreviousSetup $wrongPreviousRoot '2.5.21' | Out-Null } catch { $rejectedPath = $true }
            Assert-CcodTrue $rejectedPath 'legacy setup validator rejects an empty alternate previous-asset path'
            $state.PSObject.Properties.Remove('SeedPreviousSetup')
            $state.PreviousCalls = 0
            $result = Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart
            Assert-CcodEqual 'LegacyUpgrade' ([string]$result.phase) 'legacy upgrade returns its canonical phase'
            Assert-CcodEqual 'Completed' ([string]$result.outcome) 'legacy upgrade returns a completed outcome'
            Assert-CcodEqual 1 $state.PreviousCalls 'legacy upgrade validates the supplied previous installer once'
            Assert-CcodEqual 'LegacyUpgrade' $state.RunCalls[0] 'legacy upgrade invokes only its injected operation'
            Assert-CcodTrue ($state.CaptureCalls -contains 'LegacyUpgrade:Before') 'legacy upgrade captures the key before mutation'
            Assert-CcodTrue ($state.CaptureCalls -contains 'LegacyUpgrade:After') 'legacy upgrade captures the key after mutation'
            Assert-CcodEqual 'Capture:LegacyUpgrade:Before,Run:LegacyUpgrade,Capture:LegacyUpgrade:After' (@($state.Events) -join ',') 'legacy upgrade enforces before-operation-after ordering'
            $receiptPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '02-LegacyUpgrade.json'
            $serialized = [IO.File]::ReadAllText($receiptPath)
            foreach ($forbidden in @('C:\\Users', 'private', 'token', 'raw log')) {
                Assert-CcodTrue (-not $serialized.Contains($forbidden)) "legacy receipt omits $forbidden data"
            }
            $receipt = $serialized | ConvertFrom-Json
            Assert-CcodTrue ([bool]$receipt.facts.keyHashPreserved) 'legacy receipt records unchanged key-hash proof'
            Assert-CcodTrue ($null -ne $receipt.facts.before -and $null -ne $receipt.facts.after) 'legacy receipt persists before and after readiness observations'
            Assert-CcodEqual '2.5.21' ([string]$receipt.facts.before.version) 'legacy receipt binds the pre-upgrade observation to v2.5.21'
            Assert-CcodEqual '2.5.22' ([string]$receipt.facts.after.version) 'legacy receipt binds the post-upgrade observation to v2.5.22'
            Assert-CcodEqual '2.5.21-legacy-runtime' ([string]$receipt.facts.before.activeRuntimeId) 'legacy receipt binds the previous active runtime identity'
            Assert-CcodEqual 1 ([int]$receipt.facts.before.activeGeneration) 'legacy receipt binds the previous active generation'
            Assert-CcodEqual ('d' * 64) ([string]$receipt.facts.before.runtimeManifestSha256) 'legacy receipt binds the previous runtime manifest hash'
            Assert-CcodEqual 'runtime-2.5.22' ([string]$receipt.facts.after.activeRuntimeId) 'legacy receipt binds the candidate active runtime identity'
            Assert-CcodEqual 2 ([int]$receipt.facts.after.activeGeneration) 'legacy receipt binds the candidate active generation'
            Assert-CcodEqual ('d' * 64) ([string]$receipt.facts.after.runtimeManifestSha256) 'legacy receipt binds the candidate runtime manifest hash'
            Assert-CcodEqual ('b' * 64) ([string]$receipt.facts.before.deviceKeySha256) 'legacy receipt binds the before device-key hash'
            Assert-CcodEqual ('b' * 64) ([string]$receipt.facts.after.deviceKeySha256) 'legacy receipt binds the after device-key hash'
            Assert-CcodEqual '2.5.21' ([string]$receipt.facts.previousSetup.version) 'legacy receipt records the manifest-bound prior version'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft legacy upgrade rejects an unready v2.5.21 runtime before mutation' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            $adapters.CaptureFacts = {
                param($Context, $Point)
                if ($Context.phase -ceq 'LegacyUpgrade' -and $Point -ceq 'Before') {
                    $facts = New-CcodAcceptanceFacts -RuntimeId '2.5.21-legacy-runtime' -Generation 1 -Version '2.5.21' -KeyHash $State.KeyHash -BootId $State.BootId
                    $facts.taskState = 'Unknown'
                    return $facts
                }
                return $State.Facts
            }.GetNewClosure()
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            Assert-CcodEqual 0 $state.RunCalls.Count 'an unready previous runtime cannot reach the upgrade operation'
        } finally {
            foreach ($path in @($fixture.Root, $previousRoot)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
        }
    }

    Invoke-CcodTest 'official draft uninstall proves owned state is gone while preserving the device key hash' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $result = Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart
            Assert-CcodEqual 'Uninstall' ([string]$result.phase) 'uninstall returns its canonical phase'
            Assert-CcodEqual 'Completed' ([string]$result.outcome) 'uninstall returns a completed outcome'
            Assert-CcodEqual 'Uninstall' $state.RunCalls[1] 'uninstall invokes its injected operation after upgrade'
            $receiptPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '03-Uninstall.json'
            $serialized = [IO.File]::ReadAllText($receiptPath)
            foreach ($forbidden in @('C:\\Users', 'private', 'token', 'raw log')) {
                Assert-CcodTrue (-not $serialized.Contains($forbidden)) "uninstall receipt omits $forbidden data"
            }
            $receipt = $serialized | ConvertFrom-Json
            Assert-CcodTrue ([bool]$receipt.facts.stateRemoved) 'uninstall receipt records complete removal proof'
            Assert-CcodTrue ([bool]$receipt.facts.keyHashPreserved) 'uninstall receipt records unchanged key-hash proof'
            Assert-CcodEqual 'Absent' ([string]$receipt.facts.taskState) 'uninstall receipt records the absent scheduled task'
            Assert-CcodEqual 0 ([int]$receipt.facts.supervisorCount) 'uninstall receipt records no Supervisor'
            Assert-CcodEqual 0 ([int]$receipt.facts.trayHostCount) 'uninstall receipt records no TrayHost'
            Assert-CcodTrue ($null -ne $receipt.facts.PSObject.Properties['codexCount']) 'uninstall receipt persists the Codex absence fact'
            Assert-CcodEqual 0 ([int]$receipt.facts.codexCount) 'uninstall receipt records no Codex process'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft uninstall rejects a lingering Codex process even without debug listeners' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            $capture = $adapters.CaptureFacts
            $adapters.CaptureFacts = {
                param($Context, $Point)
                $facts = & $capture $Context $Point
                if ($Context.phase -ceq 'Uninstall' -and $Point -ceq 'After') {
                    $facts.codex = @([pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }); $facts.codexCount = 1
                }
                return $facts
            }.GetNewClosure()
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Assert-CcodThrows { Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null } 'CCOD_ACCEPTANCE_UNINSTALL_OBSERVATION_INVALID'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft uninstall rejects a lingering top-level install root' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall -LeaveInstallRootAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Assert-CcodThrows { Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null } 'CCOD_ACCEPTANCE_UNINSTALL_OBSERVATION_INVALID'
            Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '03-Uninstall.json'))) 'uninstall does not persist a receipt when the top-level root remains'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft fresh install proves one active generation and authenticated protection' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $result = Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart
            Assert-CcodEqual 'FreshInstall' ([string]$result.phase) 'fresh install returns its canonical phase'
            Assert-CcodEqual 'Completed' ([string]$result.outcome) 'fresh install returns a completed outcome'
            Assert-CcodEqual 'FreshInstall' $state.RunCalls[2] 'fresh install invokes its injected operation after uninstall'
            $receiptPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '04-FreshInstall.json'
            $serialized = [IO.File]::ReadAllText($receiptPath)
            foreach ($forbidden in @('C:\\Users', 'private', 'token', 'raw log')) {
                Assert-CcodTrue (-not $serialized.Contains($forbidden)) "fresh-install receipt omits $forbidden data"
            }
            $receipt = $serialized | ConvertFrom-Json
            Assert-CcodTrue ([bool]$receipt.facts.installReady) 'fresh-install receipt records the complete readiness proof'
            Assert-CcodEqual 1 ([int]$receipt.facts.supervisorCount) 'fresh-install receipt records one Supervisor'
            Assert-CcodEqual 1 ([int]$receipt.facts.trayHostCount) 'fresh-install receipt records one TrayHost'
            Assert-CcodTrue ([bool]$receipt.facts.trayAuthenticated) 'fresh-install receipt records authenticated TrayHost evidence'
            Assert-CcodEqual 'Completed' ([string]$receipt.facts.terminalReceipt.phase) 'fresh-install receipt records a terminal lifecycle receipt'
            Assert-CcodEqual 1 ([int]$receipt.facts.codexCount) 'fresh-install receipt records exactly one Codex process'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft pre-reboot persists a fresh-install receipt hash and boot identity before reboot' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $adapters.Reboot = {
                $State.RebootCalls++
                $stateDirectory = Join-Path $evidenceRoot 'official-draft-acceptance'
                $preRebootPath = Join-Path $stateDirectory '05-PreReboot.json'
                $freshInstallPath = Join-Path $stateDirectory '04-FreshInstall.json'
                Assert-CcodTrue (Test-Path -LiteralPath $preRebootPath -PathType Leaf) 'pre-reboot receipt is durable before reboot is requested'
                $preReboot = [IO.File]::ReadAllText($preRebootPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
                $freshInstallHash = Get-CcodTestFileSha256 -Path $freshInstallPath
                Assert-CcodEqual $freshInstallHash ([string]$preReboot.facts.freshInstallReceiptSha256) 'pre-reboot receipt carries the exact fresh-install receipt hash'
                return $true
            }.GetNewClosure()
            $result = Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot
            Assert-CcodEqual 'PreReboot' ([string]$result.phase) 'pre-reboot returns its canonical phase'
            Assert-CcodEqual 'Completed' ([string]$result.outcome) 'pre-reboot returns a completed outcome'
            Assert-CcodEqual 1 $state.BootCalls 'pre-reboot captures one boot identity'
            Assert-CcodEqual 1 $state.RebootCalls 'pre-reboot invokes exactly one injected reboot'
            $receiptPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '05-PreReboot.json'
            $receipt = ([IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json)
            Assert-CcodTrue ([bool]$receipt.facts.rebootRequested) 'pre-reboot receipt records the reboot boundary'
            Assert-CcodEqual 'boot-1' ([string]$receipt.facts.bootIdBefore) 'pre-reboot receipt records the old boot identity'
            Assert-CcodEqual (Get-CcodTestFileSha256 -Path (Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '04-FreshInstall.json')) ([string]$receipt.facts.freshInstallReceiptSha256) 'pre-reboot receipt binds the exact fresh-install receipt hash'
            Assert-CcodTrue ($null -ne $receipt.facts.observation) 'pre-reboot receipt persists the complete bounded lifecycle observation'
            foreach ($field in @('installRootPresent','installReady','activePointerPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisor','trayHost','trayHostIdentity','statusPhase','statusRuntimeId','statusCodex','lifecycleReceipt','debugPorts','debugEndpoints','deviceKeySha256')) {
                Assert-CcodTrue ($null -ne $receipt.facts.observation.PSObject.Properties[$field]) "pre-reboot observation persists $field"
            }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft pre-reboot rejects current runtime identity drift before reboot' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $state.Facts.activeGeneration = [UInt64]3
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            Assert-CcodEqual 0 $state.RebootCalls 'runtime identity drift cannot reach the reboot adapter'
        } finally {
            foreach ($path in @($fixture.Root, $previousRoot)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
        }
    }

    Invoke-CcodTest 'official draft post-reboot proves a new boot and recovered protected runtime' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts -BootId 'boot-1')
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            $state.BootId = 'boot-2'
            $state.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
            $result = Invoke-CcodAcceptancePrivate -Phase PostReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot
            Assert-CcodEqual 'PostReboot' ([string]$result.phase) 'post-reboot returns its canonical phase'
            Assert-CcodEqual 'Completed' ([string]$result.outcome) 'post-reboot returns a completed outcome'
            Assert-CcodEqual 2 $state.BootCalls 'post-reboot captures one additional boot identity'
            Assert-CcodEqual 1 $state.RebootCalls 'post-reboot does not request another reboot'
            Assert-CcodEqual 2 $state.DefenderCalls.Count 'post-reboot never invokes Defender'
            $receiptPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '06-PostReboot.json'
            $receipt = ([IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json)
            Assert-CcodTrue ([bool]$receipt.facts.bootChanged) 'post-reboot receipt records a new boot identity'
            Assert-CcodEqual 'boot-1' ([string]$receipt.facts.bootIdBefore) 'post-reboot receipt binds the pre-reboot boot'
            Assert-CcodEqual 'boot-2' ([string]$receipt.facts.bootIdAfter) 'post-reboot receipt binds the new boot'
            Assert-CcodTrue ([bool]$receipt.facts.receiptContinuity) 'post-reboot receipt records lifecycle receipt continuity'
            Assert-CcodTrue ([bool]$receipt.facts.protectionRecovered) 'post-reboot receipt records recovered protection'
            Assert-CcodEqual 'Idle' ([string]$receipt.facts.transitionStage) 'post-reboot receipt records the Idle transition'
            Assert-CcodTrue ([bool]$receipt.facts.keyHashPreserved) 'post-reboot receipt records unchanged key-hash proof'
            Assert-CcodEqual 1 ([int]$receipt.facts.codexCount) 'post-reboot receipt records exactly one Codex process'
            Assert-CcodTrue ($null -ne $receipt.facts.observation) 'post-reboot receipt persists the complete bounded lifecycle observation'
            foreach ($field in @('installRootPresent','installReady','activePointerPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisor','trayHost','trayHostIdentity','statusPhase','statusRuntimeId','statusCodex','lifecycleReceipt','debugPorts','debugEndpoints','deviceKeySha256')) {
                Assert-CcodTrue ($null -ne $receipt.facts.observation.PSObject.Properties[$field]) "post-reboot observation persists $field"
            }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft ready-for-manual-evidence requires every automated phase but never claims complete' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts -BootId 'boot-1')
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            $state.BootId = 'boot-2'; $state.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
            Invoke-CcodAcceptancePrivate -Phase PostReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            $result = Invoke-CcodAcceptancePrivate -Phase ReadyForManualEvidence -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            Assert-CcodEqual 'ReadyForManualEvidence' ([string]$result.phase) 'ready phase returns its canonical phase'
            Assert-CcodEqual 'ReadyForManualEvidence' ([string]$result.outcome) 'ready phase does not use a free-text completion result'
            Assert-CcodEqual $false ([bool]$result.complete) 'ready phase never claims Complete'
            $receiptPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '07-ReadyForManualEvidence.json'
            $serialized = [IO.File]::ReadAllText($receiptPath)
            Assert-CcodTrue ($serialized -notmatch '"outcome"\s*:\s*"Complete"') 'ready receipt contains no Complete claim'
            $receipt = $serialized | ConvertFrom-Json
            Assert-CcodEqual 6 @($receipt.facts.automatedPhases).Count 'ready receipt requires all six automated phases'
            Assert-CcodEqual $false ([bool]$receipt.facts.complete) 'ready receipt records that manual evidence is still pending'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }
    Invoke-CcodTest 'official draft rejects a tampered legacy receipt before uninstall mutation' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts)
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $legacyPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '02-LegacyUpgrade.json'
            $legacy = [IO.File]::ReadAllText($legacyPath) | ConvertFrom-Json
            $legacy.draft.id = '999'
            [IO.File]::WriteAllText($legacyPath, ($legacy | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart
            } 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_CHANGED'
            Assert-CcodEqual 1 $state.RunCalls.Count 'draft identity mismatch is rejected before uninstall mutation'
            $legacy.draft.id = '123'
            [IO.File]::WriteAllText($legacyPath, ($legacy | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            $legacy = [IO.File]::ReadAllText($legacyPath) | ConvertFrom-Json
            $legacy.facts.keyHashPreserved = $false
            [IO.File]::WriteAllText($legacyPath, ($legacy | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart
            } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            Assert-CcodEqual 1 $state.RunCalls.Count 'tampered receipt is rejected before uninstall mutation'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft default Defender adapter binds each downloaded asset to its checksum and manifest' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $fakeState = [pscustomobject]@{ Calls = [Collections.Generic.List[object]]::new() }
        $fakeModule = New-Module -ArgumentList $fakeState -ScriptBlock {
            param($State)
            function Invoke-CcodReleaseDefenderCheck {
                param($CandidatePath,$ChecksumPath,$ManifestPath,$Origin,$ExpectedVersion,$ExpectedGitCommit,$EvidencePath)
                $State.Calls.Add([pscustomobject][ordered]@{
                    CandidatePath = $CandidatePath
                    ChecksumPath = $ChecksumPath
                    ManifestPath = $ManifestPath
                    Origin = $Origin
                    ExpectedVersion = $ExpectedVersion
                    ExpectedGitCommit = $ExpectedGitCommit
                    EvidencePath = $EvidencePath
                })
                [pscustomobject]@{ fixture = $true }
            }
            Export-ModuleMember -Function Invoke-CcodReleaseDefenderCheck
        }
        try {
            &$module {
                param($Fake,$Root,$Commit,$SetupReceipt,$PortableReceipt)
                $script:CcodOfficialDraftDefenderModule = $Fake
                $defaults = Get-CcodOfficialDraftDefaultAdapters
                & $defaults.InvokeDefenderCheck $Root 'Setup' 'InternetDownload' '2.5.22' $Commit $SetupReceipt | Out-Null
                & $defaults.InvokeDefenderCheck $Root 'PortableZip' 'InternetDownload' '2.5.22' $Commit $PortableReceipt | Out-Null
            } $fakeModule $fixture.Root $fixture.GitCommit (Join-Path $fixture.Root 'setup-receipt.json') (Join-Path $fixture.Root 'portable-receipt.json')
            Assert-CcodEqual 2 $fakeState.Calls.Count 'default Defender adapter invokes the checker once per downloaded asset'
            $setup = $fakeState.Calls[0]
            Assert-CcodEqual (Join-Path $fixture.Root $fixture.Names[5]) ([string]$setup.CandidatePath) 'Setup scan uses the Setup executable'
            Assert-CcodEqual (Join-Path $fixture.Root $fixture.Names[6]) ([string]$setup.ChecksumPath) 'Setup scan uses its checksum'
            Assert-CcodEqual (Join-Path $fixture.Root $fixture.Names[10]) ([string]$setup.ManifestPath) 'Setup scan uses its release manifest'
            $portable = $fakeState.Calls[1]
            Assert-CcodEqual (Join-Path $fixture.Root $fixture.Names[0]) ([string]$portable.CandidatePath) 'portable scan uses the ZIP'
            Assert-CcodEqual (Join-Path $fixture.Root $fixture.Names[1]) ([string]$portable.ChecksumPath) 'portable scan uses its checksum'
            Assert-CcodEqual (Join-Path $fixture.Root $fixture.Names[4]) ([string]$portable.ManifestPath) 'portable scan uses its release manifest'
        } finally {
            if ($null -ne $fakeModule) { Remove-Module -Name $fakeModule.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft schemas reject non-integer numbers and scalar arrays' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodTrue (-not (& $module { param($Value) Test-CcodOfficialDraftPositiveInteger $Value } ([double]2.0))) 'floating point pseudo-integer is rejected'
            Assert-CcodTrue (-not (& $module { param($Value) Test-CcodOfficialDraftPositiveInteger $Value } ([decimal]2))) 'decimal pseudo-integer is rejected'
            $freshFacts = New-CcodAcceptanceFacts
            $freshFacts.activeGeneration = [double]2
            Assert-CcodThrows {
                &$module { param($Facts,$KeyHash) Assert-CcodOfficialDraftFreshFacts -Facts $Facts -ExpectedKeyHash $KeyHash } $freshFacts ('b' * 64) | Out-Null
            } 'CCOD_ACCEPTANCE_FRESH_INSTALL_OBSERVATION_INVALID'
            $receipt = New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType Setup
            $receipt.assetName = @([string]$receipt.assetName)
            $candidate = [pscustomobject][ordered]@{
                version = $fixture.Version; gitCommit = $fixture.GitCommit
                assetHashes = @($fixture.Contract.Assets)
                manifestHashes = [pscustomobject][ordered]@{ portable = $fixture.Contract.PortableManifestSha256; setup = $fixture.Contract.SetupManifestSha256 }
            }
            Assert-CcodThrows {
                &$module { param($Receipt,$Candidate) Assert-CcodOfficialDraftDefenderReceipt -Receipt $Receipt -Candidate $Candidate -AssetType Setup } $receipt $candidate | Out-Null
            } 'CCOD_ACCEPTANCE_DEFENDER_RECEIPT_INVALID'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fixture -and (Test-Path -LiteralPath $fixture.Root)) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft phase operation requires completed and outcome to agree' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $state = [pscustomobject]@{ RunCalls = [Collections.Generic.List[string]]::new() }
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state
            $adapters.RunPhase = { param($Context) [pscustomobject][ordered]@{ completed = $false; outcome = 'Completed'; installerSha256 = [string]$fixture.Contract.Assets[5].sha256; runtimeManifestSha256 = ('1' * 64) } }.GetNewClosure()
            $context = [pscustomobject][ordered]@{
                setupPath = Join-Path $fixture.Root $fixture.Names[5]
                candidate = [pscustomobject][ordered]@{ assetHashes = @($fixture.Contract.Assets) }
            }
            Assert-CcodThrows {
                &$module { param($Adapters,$Context) Invoke-CcodOfficialDraftPhaseOperation -Adapters $Adapters -Context $Context } $adapters $context | Out-Null
            } 'CCOD_ACCEPTANCE_MACHINE_OPERATION_FAILED'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft persisted hash validators use absolute end anchors' {
        $source = [IO.File]::ReadAllText($modulePath, [Text.UTF8Encoding]::new($false))
        Assert-CcodTrue (-not $source.Contains("'^[0-9a-f]{40}$'")) 'acceptance commit validators reject trailing newline variants'
        Assert-CcodTrue (-not $source.Contains("'^[0-9a-f]{64}$'")) 'acceptance hash validators reject trailing newline variants'
    }

    Invoke-CcodTest 'official draft JSONL rejects duplicate object properties' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows { &$module { param($Raw) Assert-CcodOfficialDraftJsonNoDuplicateProperties -Raw $Raw } '{"code":"first","code":"second"}' } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            Assert-CcodThrows { &$module { param($Raw) Assert-CcodOfficialDraftJsonNoDuplicateProperties -Raw $Raw } '{"code":"first","\u0063ode":"second"}' } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
        } finally { if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue } }
    }

    Invoke-CcodTest 'official draft debug endpoints require an owning verified process' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows { &$module { param($Endpoints) Assert-CcodOfficialDraftDebugEndpointOwnership -Endpoints $Endpoints -ExpectedPorts @(9229) -ExpectedPid 13948 -ExpectedCreationTimeUtc '2030-02-03T04:05:02.0000000Z' } @([pscustomobject]@{ localAddress = '127.0.0.1'; localPort = 9229 }) } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally { if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue } }
    }

    Invoke-CcodTest 'official draft debug endpoint owning process rejects Int32 wrapping values' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $endpoint = [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = [uint64]4294981244; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            Assert-CcodThrows { &$module { param($Endpoints) Assert-CcodOfficialDraftDebugEndpointOwnership -Endpoints $Endpoints -ExpectedPorts @(9229) -ExpectedPid 13948 -ExpectedCreationTimeUtc '2030-02-03T04:05:02.0000000Z' } @($endpoint) } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally { if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue } }
    }

    Invoke-CcodTest 'official draft tray and remote proofs reject noncanonical timestamps' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $tray = [pscustomobject][ordered]@{ timestampUtc = '2030-02-03T04:05:06+00:00'; command = 'ShowAbout'; revision = [UInt64]1; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }
            Assert-CcodThrows { &$module { param($Proof) ConvertTo-CcodOfficialDraftTrayProof -Proof $Proof -Operation About } $tray } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            $remote = [pscustomobject][ordered]@{
                schemaVersion = 1; timestampUtc = '2030-02-03T04:05:06+00:00'; kind = 'remote-control-manual-proof'; operation = 'SecondDeviceControl'; deviceRole = 'SecondDevice'; challenge = 'run-1'; candidateVersion = '2.5.22'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64); attestation = 'HumanReviewedStructuredAttestation'; connection = 'Connected'; control = 'Completed'; outcome = 'Completed'; code = 'CCOD_REMOTE_ACTION_COMPLETED'
            }
            Assert-CcodThrows { &$module { param($Proof) ConvertTo-CcodOfficialDraftRemoteProof -Proof $Proof } $remote } 'CCOD_ACCEPTANCE_REMOTE_UNPROVEN'
        } finally { if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue } }
    }

    Invoke-CcodTest 'official draft tray proof requires a real terminal action record' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-tray-proof-' + [guid]::NewGuid().ToString('N'))
        $log = Join-Path $root 'supervisor.log'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $record = [ordered]@{ schemaVersion = 1; timestampUtc = '2030-02-03T04:05:07.0000000Z'; component = 'Supervisor'; stage = 'TrayAction'; code = 'CCOD_TRAY_ACTION_COMPLETED'; outcome = 'Completed'; command = 'ShowAbout'; revision = [UInt64]1; status = 'Completed' }
        [IO.File]::WriteAllText($log, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $proof = &$module { param($Path) Get-CcodOfficialDraftTrayActionProof -Path $Path -Operation About -NotBefore ([DateTimeOffset]::Parse('2030-02-03T04:05:06.0000000Z')) } $log
            Assert-CcodEqual 'ShowAbout' ([string]$proof.command) 'tray proof binds the actual command'
            [IO.File]::WriteAllText($log, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($Path) Get-CcodOfficialDraftTrayActionProof -Path $Path -Operation About } $log | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            $arrayRecord = [ordered]@{}
            foreach ($key in $record.Keys) { $arrayRecord[$key] = $record[$key] }
            $arrayRecord.stage = @('TrayAction')
            [IO.File]::WriteAllText($log, (($arrayRecord | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($Path) Get-CcodOfficialDraftTrayActionProof -Path $Path -Operation About } $log | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            [IO.File]::WriteAllText($log, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine + '{"stage":"TrayAction"}' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($Path) Get-CcodOfficialDraftTrayActionProof -Path $Path -Operation About -NotBefore ([DateTimeOffset]::Parse('2030-02-03T04:05:06.0000000Z')) } $log | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            [IO.File]::WriteAllText($log, 'completed', [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($Path) Get-CcodOfficialDraftTrayActionProof -Path $Path -Operation About } $log | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft tray ready proof selects the current host from historical records' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-tray-ready-history-' + [guid]::NewGuid().ToString('N'))
        $logDirectory = Join-Path $root 'logs'
        $log = Join-Path $logDirectory 'supervisor.log'
        $module = $null
        try {
            [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
            $base = [ordered]@{ schemaVersion = 1; timestampUtc = '2030-02-03T04:05:07.0000000Z'; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.21'; hostPid = 101; hostCreationTimeUtc = '2030-02-03T04:04:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2 }
            $current = [ordered]@{ schemaVersion = 1; timestampUtc = $base.timestampUtc; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2 }
            [IO.File]::WriteAllText($log, (($base | ConvertTo-Json -Compress) + [Environment]::NewLine + ($current | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $proof = &$module { param($InstallRoot,$Hosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts $Hosts } $root @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            Assert-CcodTrue ($null -ne $proof -and [int]$proof.hostPid -eq 201) 'current TrayHost identity is selected from historical ready records'
            $oldRuntimeCurrentHost = [ordered]@{}
            foreach ($key in $current.Keys) { $oldRuntimeCurrentHost[$key] = $current[$key] }
            $oldRuntimeCurrentHost.runtimeId = 'runtime-2.5.21'
            [IO.File]::WriteAllText($log, (($oldRuntimeCurrentHost | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $oldRuntimeProof = &$module { param($InstallRoot,$Hosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts $Hosts } $root @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            Assert-CcodTrue ($null -eq $oldRuntimeProof) 'matching process identity from another runtime cannot prove current readiness'
            $offsetReady = [ordered]@{}
            foreach ($key in $current.Keys) { $offsetReady[$key] = $current[$key] }
            $offsetReady.hostCreationTimeUtc = '2030-02-03T04:05:01.0000000+00:00'
            [IO.File]::WriteAllText($log, (($base | ConvertTo-Json -Compress) + [Environment]::NewLine + ($offsetReady | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($InstallRoot,$Hosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts $Hosts } $root @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }) } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            $arrayReady = [ordered]@{}
            foreach ($key in $current.Keys) { $arrayReady[$key] = $current[$key] }
            $arrayReady.stage = @('TrayHostReady')
            [IO.File]::WriteAllText($log, (($base | ConvertTo-Json -Compress) + [Environment]::NewLine + ($arrayReady | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($InstallRoot,$Hosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts $Hosts } $root @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }) } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            $withinCompatibility = [ordered]@{ schemaVersion = 1; timestampUtc = $base.timestampUtc; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000001Z'; protocolMajor = 2; capabilities = 7 }
            [IO.File]::WriteAllText($log, (($base | ConvertTo-Json -Compress) + [Environment]::NewLine + ($withinCompatibility | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $withinProof = &$module { param($InstallRoot,$Hosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts $Hosts } $root @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            Assert-CcodTrue ($null -eq $withinProof) 'native creation identity requires exact equality even within one CIM microsecond'
            $near = [ordered]@{ schemaVersion = 1; timestampUtc = $base.timestampUtc; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000010Z'; protocolMajor = 2; capabilities = 7 }
            [IO.File]::WriteAllText($log, (($base | ConvertTo-Json -Compress) + [Environment]::NewLine + ($near | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $nearProof = &$module { param($InstallRoot,$Hosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts $Hosts } $root @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            Assert-CcodTrue ($null -eq $nearProof) 'creation identity outside the observed native instant is rejected'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'default capture preserves exact native tray readiness and collector rejection' {
        $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-native-ready-capture-'+[guid]::NewGuid().ToString('N'))
        $logs=Join-Path $root 'logs';$log=Join-Path $logs 'supervisor.log';$module=$null;$integration=$null
        try {
            [IO.Directory]::CreateDirectory($logs)|Out-Null
            $facts=New-CcodAcceptanceRawFacts
            $facts.trayHost[0].CreationTimeUtc='2030-02-03T04:05:01.0000006Z'
            $facts.trayHostIdentity.creationTimeUtc=$facts.trayHost[0].CreationTimeUtc
            $state=[pscustomobject]@{Facts=$facts;Calls=0;ProofCalls=0;OverrideAuth=$null}
            $record=[ordered]@{schemaVersion=1;timestampUtc='2030-02-03T04:05:07.0000000Z';component='Supervisor';stage='TrayHostReady';code='CCOD_TRAYHOST_READY';outcome='Completed';runtimeId=$facts.activeRuntimeId;hostPid=201;hostCreationTimeUtc=$facts.trayHost[0].CreationTimeUtc;protocolMajor=2;capabilities=2}
            [IO.File]::WriteAllText($log,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
            $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $integration=&$module {Get-CcodOfficialDraftIntegrationModule}
            &$integration {
                param($State)
                $script:CcodNativeReadyState=$State
                function script:Get-CcodInstalledLifecycleFacts {
                    param($InstallRoot,$ExpectedVersion)
                    $s=$script:CcodNativeReadyState;$s.Calls++;$value=$s.Facts.PSObject.Copy();$s.ProofCalls++
                    $value.trayAuthenticated=Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId $value.activeRuntimeId -TrayHost $value.trayHost
                    if($null-ne$s.OverrideAuth){$value.trayAuthenticated=$s.OverrideAuth}
                    return $value
                }
            } $state
            $capture=&$module {param($Root,$Integration)$script:CcodOfficialDraftInstallRoot=$Root;$script:CcodOfficialDraftIntegrationModule=$Integration;(Get-CcodOfficialDraftDefaultAdapters).CaptureFacts} $root $integration
            $context=[pscustomobject]@{phase='PostReboot';expectedVersion='2.5.22'}
            $positive=&$capture $context 'After'
            Assert-CcodTrue $positive.trayAuthenticated 'exact nonzero native tick identity passes both real matchers'
            Assert-CcodTrue $positive.protectionReady 'positive default capture proves readiness'
            $record.hostCreationTimeUtc='2030-02-03T04:05:01.0000007Z'
            [IO.File]::WriteAllText($log,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
            $changed=&$capture $context 'After'
            Assert-CcodEqual 2 $state.ProofCalls 'changed identity reaches real integration matcher'
            Assert-CcodEqual $false $changed.trayAuthenticated 'one changed native tick cannot regain authentication in default capture'
            Assert-CcodEqual $false $changed.protectionReady 'mismatched native identity is not protection ready'
            $record.hostCreationTimeUtc=$facts.trayHost[0].CreationTimeUtc
            [IO.File]::WriteAllText($log,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
            $state.OverrideAuth=$false
            $rejected=&$capture $context 'After'
            Assert-CcodEqual $false $rejected.trayAuthenticated 'exact log cannot override collector authentication rejection'
            foreach($invalid in @('true',1,@($true))){$state.OverrideAuth=$invalid;Assert-CcodThrows {&$capture $context 'After'|Out-Null} 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'}
            $state.OverrideAuth=$null
            Assert-CcodTrue ((&$capture $context 'After').protectionReady) 'clean retry is possible after rejected observations'
        } finally {
            if($null-ne$integration){Remove-Module $integration -Force -ErrorAction SilentlyContinue}
            if($null-ne$module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
            if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
        }
    }

    Invoke-CcodTest 'official draft tray ready proof rejects noncanonical timestamps' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-tray-ready-timestamp-' + [guid]::NewGuid().ToString('N'))
        $logDirectory = Join-Path $root 'logs'
        $log = Join-Path $logDirectory 'supervisor.log'
        $module = $null
        try {
            [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
            $record = [ordered]@{ schemaVersion = 1; timestampUtc = 'not-a-canonical-utc'; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2 }
            [IO.File]::WriteAllText($log, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            Assert-CcodThrows { &$module { param($InstallRoot) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId 'runtime-2.5.22' -TrayHosts @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }) } $root } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default tray operation verifies live and redacted terminal records' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-tray-operation-' + [guid]::NewGuid().ToString('N'))
        $logDirectory = Join-Path $root 'logs'
        $liveLog = Join-Path $logDirectory 'supervisor.log'
        $redactedLog = Join-Path $root 'redacted.log'
        $screenshot = Join-Path $root 'screenshot.png'
        [IO.Directory]::CreateDirectory((Join-Path $root 'runtime')) | Out-Null
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), '{}', [Text.UTF8Encoding]::new($false))
        $future = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)
        $readyRecord = [ordered]@{ schemaVersion = 1; timestampUtc = $future; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2 }
        $actionRecord = [ordered]@{ schemaVersion = 1; timestampUtc = $future; component = 'Supervisor'; stage = 'TrayAction'; code = 'CCOD_TRAY_ACTION_COMPLETED'; outcome = 'Completed'; command = 'ShowAbout'; revision = [UInt64]1; status = 'Completed' }
        $serialized = (($readyRecord | ConvertTo-Json -Compress) + "`n" + ($actionRecord | ConvertTo-Json -Compress) + [Environment]::NewLine)
        [IO.File]::WriteAllText($liveLog, $serialized, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($redactedLog, (($actionRecord | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($screenshot, 'fixture screenshot', [Text.UTF8Encoding]::new($false))
        $facts = [pscustomobject][ordered]@{
            installRootPresent = $true; appPresent = $true; runtimeRootPresent = $true; activePointerPresent = $true; activeRuntimeId = 'runtime-2.5.22'; activeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64)
            supervisor = @([pscustomobject]@{ Pid = 200; CreationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
            trayHost = @([pscustomobject]@{ Pid = 201; CreationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }
            codex = @([pscustomobject]@{ Pid = 202; CreationTimeUtc = '2030-02-03T04:05:02.0000000Z' })
            trayAuthenticated = $true
            taskState = 'Ready'; statusPhase = 'Active'; statusRuntimeId = 'runtime-2.5.22'
            statusCodex = [pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            transitionStage = 'Idle'; lifecycleReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; phase = 'Completed' }
            aboutVersion = '2.5.22'; deviceKeyPresent = $true; deviceKeySha256 = ('b' * 64)
            shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
            debugEndpoints = @([pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' },[pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' })
            debugPorts = @(9229,9230)
        }
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param([string]$InstallRoot,[string]$ExpectedVersion); return $Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodEqual $null $facts.PSObject.Properties['codexCount'] 'raw integration output has identities rather than a precomputed codex count'
            $observation = &$module {
                param($InstallRoot,$EvidencePath,$FakeIntegration,$ScreenshotPath)
                $script:CcodOfficialDraftManualAcknowledgement = { param([string]$Prompt) return 'CCOD_MANUAL_ABOUT_COMPLETED' }
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $script:CcodOfficialDraftIntegrationModule = $FakeIntegration
                $adapters = Get-CcodOfficialDraftDefaultAdapters
                $context = [pscustomobject][ordered]@{ screenshotPath = $ScreenshotPath; redactedLogPath = $EvidencePath; expectedVersion = '2.5.22'; manualAcknowledgement = 'CCOD_MANUAL_ABOUT_COMPLETED' }
                $captured = & $adapters.CaptureFacts ([pscustomobject]@{ phase = 'PostReboot'; expectedVersion = '2.5.22' }) 'After'
                $result = & $adapters.RunManualOperation $context 'About'
                [pscustomobject]@{ Captured = $captured; Result = $result; Capture = $adapters.CaptureFacts }
            } $root $redactedLog $fakeIntegration $screenshot
            $result = $observation.Result
            Assert-CcodEqual 1 $observation.Captured.codexCount 'default capture derives the count from the observed identities'
            Assert-CcodEqual 'Idle' $observation.Captured.transitionStage 'default capture preserves transition state for core validation'
            $coreObservation = & $module { param($Captured) ConvertTo-CcodOfficialDraftLegacyObservation -Facts $Captured -ExpectedVersion '2.5.22' } $observation.Captured
            Assert-CcodEqual '2.5.22' $coreObservation.version 'actual default capture output passes the strict core observation contract'
            Assert-CcodEqual 1 $coreObservation.codex.Count 'strict core observes the same single Codex identity'
            foreach ($kind in @('supervisor','trayHost','codex')) {
                Assert-CcodEqual 'pid,creationTimeUtc' ($observation.Captured.$kind[0].PSObject.Properties.Name -join ',') 'native producer identity fields become the canonical core schema'
            }
            $captureContext = [pscustomobject]@{ phase = 'PostReboot'; expectedVersion = '2.5.22' }
            $facts.transitionStage = 'NotIdle'
            $busy = & $observation.Capture $captureContext 'After'
            Assert-CcodEqual 'NotIdle' $busy.transitionStage 'nonterminal transition state is retained'
            Assert-CcodEqual $false $busy.protectionReady 'busy transition cannot be promoted to ready by the adapter'
            $facts.transitionStage = 'Idle'
            $facts.activeGeneration = @([UInt64]2)
            Assert-CcodThrows { & $observation.Capture $captureContext 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            $facts.activeGeneration = [UInt64]2
            $facts.transitionStage = @('Idle')
            Assert-CcodThrows { & $observation.Capture $captureContext 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            $facts.transitionStage = 'Idle'
            $facts.codex[0].Pid = '202'
            Assert-CcodThrows { & $observation.Capture $captureContext 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            $facts.codex[0].Pid = 202
            $facts | Add-Member -NotePropertyName codexCount -NotePropertyValue 2
            Assert-CcodThrows { & $observation.Capture $captureContext 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            $facts.PSObject.Properties.Remove('codexCount')
            Assert-CcodTrue ([bool]$result.verified) 'default tray adapter returns verified only after both terminal records match'
            Assert-CcodEqual 'CCOD_TRAYABOUT_COMPLETED' ([string]$result.code) 'default tray adapter returns the canonical operation code'
            Assert-CcodTrue ($result.screenshotSha256 -is [string] -and $result.screenshotSha256 -match '^[0-9a-f]{64}\z') 'default tray adapter captures the screenshot hash'
            Assert-CcodTrue ($result.redactedLogSha256 -is [string] -and $result.redactedLogSha256 -match '^[0-9a-f]{64}\z') 'default tray adapter captures the redacted log hash'
            $bad = &$module {
                param($InstallRoot,$EvidencePath,$FakeIntegration,$ScreenshotPath)
                $script:CcodOfficialDraftManualAcknowledgement = { param([string]$Prompt) return 'CCOD_MANUAL_ABOUT_COMPLETED' }
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $script:CcodOfficialDraftIntegrationModule = $FakeIntegration
                $adapters = Get-CcodOfficialDraftDefaultAdapters
                $context = [pscustomobject][ordered]@{ screenshotPath = $ScreenshotPath; redactedLogPath = $EvidencePath; expectedVersion = '2.5.22'; expectedRuntimeId = 'runtime-other'; manualAcknowledgement = 'CCOD_MANUAL_ABOUT_COMPLETED' }
                try { & $adapters.RunManualOperation $context 'About' | Out-Null; return $null } catch { return $_ }
            } $root $redactedLog $fakeIntegration $screenshot
            Assert-CcodTrue ($null -ne $bad -and [string]$bad.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN*') 'default tray adapter binds manual proof to the persisted runtime identity'
        } finally {
            if ($null -ne $module) { & $module { $script:CcodOfficialDraftManualAcknowledgement = $null }; Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default absent observation preserves empty arrays and null state' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-absent-capture-' + [guid]::NewGuid().ToString('N'))
        $facts = [pscustomobject][ordered]@{
            installRootPresent = $false; appPresent = $false; runtimeRootPresent = $false; activePointerPresent = $false
            activeRuntimeId = $null; activeGeneration = $null; runtimeManifestSha256 = $null
            supervisor = @(); trayHost = @(); codex = @(); taskState = 'Absent'; statusPhase = 'Unavailable'
            statusRuntimeId = $null; statusCodex = $null; transitionStage = 'Unavailable'; lifecycleReceipt = $null; aboutVersion = $null
            deviceKeyPresent = $true; deviceKeySha256 = ('b' * 64)
            shortcuts = [pscustomobject][ordered]@{ startMenu = $false; desktop = $false }
            debugPorts = @(); debugEndpoints = @()
        }
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param($InstallRoot,$ExpectedVersion) return $Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $captured = & $module {
                param($InstallRoot,$Integration)
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $script:CcodOfficialDraftIntegrationModule = $Integration
                $defaults = Get-CcodOfficialDraftDefaultAdapters
                & $defaults.CaptureFacts ([pscustomobject]@{ phase = 'Uninstall'; expectedVersion = '2.5.22' }) 'After'
            } $root $fakeIntegration
            Assert-CcodEqual $false $captured.installRootPresent 'the read-only capture preserves an actually absent fixture root'
            Assert-CcodEqual $false $captured.protectionReady 'absence is never turned into protection readiness'
            Assert-CcodEqual 0 $captured.codexCount 'empty producer identities yield zero observed Codex roots'
            foreach ($kind in @('supervisor','trayHost','codex')) {
                Assert-CcodTrue ($captured.$kind -is [array] -and $captured.$kind.Count -eq 0) 'empty native identity arrays remain arrays'
            }
            Assert-CcodEqual $null $captured.activeGeneration 'null generation remains null rather than a synthetic zero'
            Assert-CcodEqual 'Unavailable' $captured.transitionStage 'absent transition observation is retained'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft uninstall reuses captured ports and rejects every residual binding' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-census-' + [guid]::NewGuid().ToString('N'))
        $originalNetTcp = ${function:Get-NetTCPConnection}
        $module = $null; $fakeIntegration = $null
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            $before = New-CcodAcceptanceFacts
            $before | Add-Member -NotePropertyName appPresent -NotePropertyValue $true
            $before.PSObject.Properties.Remove('codexCount')
            $after = New-CcodAcceptanceFacts -Absent
            $after | Add-Member -NotePropertyName appPresent -NotePropertyValue $false
            $after | Add-Member -NotePropertyName aboutVersion -NotePropertyValue $null
            $after.PSObject.Properties.Remove('codexCount')
            $state = [pscustomobject]@{ Facts = $before; Listeners = @(); StatusReads = 0; CensusCalls = 0; FailEnumeration = $false }
            # Capture a mutable fixture reference without shadowing the cmdlet's State parameter.
            $censusState = $state
            Set-Item -LiteralPath Function:\global:Get-NetTCPConnection -Value ({
                param($State,$ErrorAction)
                if ($censusState.FailEnumeration) { throw [IO.IOException]::new('fixture census unavailable') }
                return @($censusState.Listeners)
            }.GetNewClosure())
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $realIntegration = & $module { Get-CcodOfficialDraftIntegrationModule }
            $fakeIntegration = New-Module -ArgumentList $state,$realIntegration -ScriptBlock {
                param($State,$RealIntegration)
                function Get-CcodInstalledLifecycleFacts { param($InstallRoot,$ExpectedVersion) return $State.Facts }
                function Read-CcodInstalledLifecycleStatusFact {
                    param($StateRoot)
                    $State.StatusReads++
                    [pscustomobject]@{ session = [pscustomobject]@{ codex = [pscustomobject]@{ mainPort = 9229; rendererPort = 9230 } } }
                }
                function Test-CcodInstalledLifecycleDebugPortsClosed {
                    param($Ports)
                    $State.CensusCalls++
                    & $RealIntegration { param($CapturedPorts) Test-CcodInstalledLifecycleDebugPortsClosed -Ports $CapturedPorts } $Ports
                }
                Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts,Read-CcodInstalledLifecycleStatusFact,Test-CcodInstalledLifecycleDebugPortsClosed
            }
            $capture = & $module {
                param($InstallRoot,$Integration)
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $script:CcodOfficialDraftIntegrationModule = $Integration
                (Get-CcodOfficialDraftDefaultAdapters).CaptureFacts
            } $root $fakeIntegration
            $context = [pscustomobject]@{ phase = 'Uninstall'; expectedVersion = '2.5.22' }
            $capturedBefore = & $capture $context 'Before'
            Assert-CcodEqual '9229,9230' ($capturedBefore.debugPorts -join ',') 'before capture retains the observed port pair'
            Assert-CcodEqual 0 $state.StatusReads 'port capture does not reopen mutable status after taking the observation'
            $state.Facts = $after
            Remove-Item -LiteralPath $root -Recurse -Force
            $capturedAfter = & $capture $context 'After'
            Assert-CcodEqual 1 $state.CensusCalls 'after capture uses the real closed-port census despite removed status'
            $key = & $module { param($Facts) Assert-CcodOfficialDraftUninstallFacts -Facts $Facts -ExpectedKeyHash ('b' * 64) } $capturedAfter
            Assert-CcodEqual ('b' * 64) $key 'complete absence retains the expected key hash'
            foreach ($port in @(9229,9230)) { foreach ($address in @('127.0.0.1','0.0.0.0','::','192.0.2.1')) {
                $state.Listeners = @([pscustomobject]@{ LocalAddress = $address; LocalPort = [uint16]$port; OwningProcess = [uint32]4 })
                Assert-CcodThrows { & $capture $context 'After' | Out-Null } 'CCOD_ACCEPTANCE_UNINSTALL_OBSERVATION_INVALID'
            } }
            $state.Listeners = @([pscustomobject]@{ LocalAddress = '::'; LocalPort = [uint16]443; OwningProcess = [uint32]4 })
            $unrelated = & $capture $context 'After'
            Assert-CcodEqual 0 $unrelated.debugEndpoints.Count 'unrelated listeners are not evidence of a retained product endpoint'
            $state.FailEnumeration = $true
            Assert-CcodThrows { & $capture $context 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally {
            if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\global:Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath Function:\global:Get-NetTCPConnection -Value $originalNetTcp }
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'manual proof rejects ABA file and ancestor replacement between hashing and parsing' {
        foreach ($operation in @('About','SecondDeviceControl')) { foreach ($attack in @('File','Directory')) {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-proof-aba-' + [guid]::NewGuid().ToString('N'))
            $module = $null; $fakeIntegration = $null
            try {
                $evidence = Join-Path $root 'evidence'
                [IO.Directory]::CreateDirectory($evidence) | Out-Null
                [IO.Directory]::CreateDirectory((Join-Path $root 'logs')) | Out-Null
                $target = Join-Path $evidence 'redacted.log'
                $screenshot = Join-Path $root 'screenshot.bin'
                [IO.File]::WriteAllText($screenshot,'fixture image',[Text.UTF8Encoding]::new($false))
                $freshTime = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')
                $freshTime = [DateTimeOffset]::Parse($freshTime).UtcDateTime.ToString('o')
                $ready = [ordered]@{ schemaVersion = 1; timestampUtc = $freshTime; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = 7 }
                $action = [ordered]@{ schemaVersion = 1; timestampUtc = $freshTime; component = 'Supervisor'; stage = 'TrayAction'; code = 'CCOD_TRAY_ACTION_COMPLETED'; outcome = 'Completed'; command = 'ShowAbout'; revision = 1; status = 'Completed' }
                [IO.File]::WriteAllText((Join-Path $root 'logs\supervisor.log'), (($ready | ConvertTo-Json -Compress) + "`n" + ($action | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
                $proof = if ($operation -ceq 'About') { $action } else {
                    [ordered]@{ schemaVersion = 1; timestampUtc = $freshTime; kind = 'remote-control-manual-proof'; operation = 'SecondDeviceControl'; deviceRole = 'SecondDevice'; challenge = 'fixture-challenge'; candidateVersion = '2.5.22'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = 2; runtimeManifestSha256 = ('d' * 64); attestation = 'HumanReviewedStructuredAttestation'; connection = 'Connected'; control = 'Completed'; outcome = 'Completed'; code = 'CCOD_REMOTE_ACTION_COMPLETED' }
                }
                $goodBytes = [Text.UTF8Encoding]::new($false).GetBytes(($proof | ConvertTo-Json -Compress) + "`n")
                $oldProof = [ordered]@{}
                foreach ($key in $proof.Keys) { $oldProof[$key] = $proof[$key] }
                $oldProof.timestampUtc = [DateTime]::UtcNow.AddDays(-1).ToString('o')
                $oldBytes = [Text.UTF8Encoding]::new($false).GetBytes(($oldProof | ConvertTo-Json -Compress) + "`n")
                [IO.File]::WriteAllBytes($target,$goodBytes)
                $facts = New-CcodAcceptanceFacts
                $facts | Add-Member -NotePropertyName appPresent -NotePropertyValue $true
                $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
                    param($Facts)
                    function Get-CcodInstalledLifecycleFacts { param($InstallRoot,$ExpectedVersion,$ExpectedDebugPorts) return $Facts }
                    Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
                }
                $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
                $run = & $module {
                    param($Root,$Integration)
                    $script:CcodOfficialDraftInstallRoot = $Root
                    $script:CcodOfficialDraftIntegrationModule = $Integration
                    (Get-CcodOfficialDraftDefaultAdapters).RunManualOperation
                } $root $fakeIntegration
                $context = [pscustomobject]@{ screenshotPath = $screenshot; redactedLogPath = $target; expectedVersion = '2.5.22'; manualChallenge = 'fixture-challenge'; manualAcknowledgement = ('CCOD_MANUAL_' + $operation.ToUpperInvariant() + '_COMPLETED') }
                $control = & $run $context $operation
                Assert-CcodTrue $control.verified 'the real manual operation reaches a valid proof before the attack'
                [IO.File]::WriteAllBytes($target,$oldBytes)
                $oldHash = Get-CcodTestFileSha256 $target
                $state = [pscustomobject]@{ Target = $target; Parent = $evidence; Backup = ($evidence + '-moved'); OldBytes = $oldBytes; GoodBytes = $goodBytes; Mode = $attack; Attempts = 0; Replaced = $false }
                & $module {
                    param($State)
                    $script:CcodProofRace = $State
                    $script:CcodProofRaceOriginal = ${function:Get-CcodOfficialDraftJsonLines}
                    function script:Get-CcodOfficialDraftJsonLines {
                        param([string]$Path,[AllowNull()][Nullable[DateTimeOffset]]$NotBefore)
                        $race = $script:CcodProofRace
                        if ($Path -cne $race.Target) { return & $script:CcodProofRaceOriginal -Path $Path -NotBefore $NotBefore }
                        $race.Attempts++
                        $changed = $false
                        try {
                            if ($race.Mode -ceq 'Directory') {
                                [IO.Directory]::Move($race.Parent,$race.Backup)
                                $changed = $true
                                [IO.Directory]::CreateDirectory($race.Parent) | Out-Null
                            }
                            [IO.File]::WriteAllBytes($race.Target,$race.GoodBytes)
                            $changed = $true; $race.Replaced = $true
                            return & $script:CcodProofRaceOriginal -Path $Path -NotBefore $NotBefore
                        } finally {
                            if ($changed) {
                                if ($race.Mode -ceq 'Directory') { [IO.Directory]::Delete($race.Parent,$true); [IO.Directory]::Move($race.Backup,$race.Parent) }
                                else { [IO.File]::WriteAllBytes($race.Target,$race.OldBytes) }
                            }
                        }
                    }
                } $state
                $accepted = $false
                try { $result = & $run $context $operation; $accepted = [bool]$result.verified } catch { }
                Assert-CcodEqual 1 $state.Attempts 'the attack reaches the actual semantic-read boundary'
                Assert-CcodEqual $oldHash (Get-CcodTestFileSha256 $target) 'the ABA sequence retains the original hashed bytes'
                Assert-CcodEqual $false $accepted 'an ABA-swapped proof cannot be accepted under the original file hash'
                Assert-CcodEqual $false $state.Replaced 'held file and ancestor authority blocks replacement'
                [IO.File]::WriteAllBytes($target,$goodBytes)
                Assert-CcodTrue ((Get-CcodTestFileSha256 $target) -cne $oldHash) 'failure releases evidence handles for a later legitimate retry'
            } finally {
                if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
                if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            }
        } }
    }

    Invoke-CcodTest 'manual read authority rejects existing writers and releases partial acquisition' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-evidence-read-lease-' + [guid]::NewGuid().ToString('N'))
        $module = $null; $writer = $null; $lease = $null
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            $first = Join-Path $root 'first evidence.bin'
            $second = Join-Path $root 'second.log'
            [IO.File]::WriteAllText($first,'first original')
            [IO.File]::WriteAllText($second,'second original')
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $writer = [IO.File]::Open($second,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            Assert-CcodThrows { & $module { param($Paths) Open-CcodOfficialDraftEvidenceReadLease -Paths $Paths } @($first,$second) | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            [IO.File]::WriteAllText($first,'first after rejected acquisition')
            Assert-CcodEqual 'first after rejected acquisition' ([IO.File]::ReadAllText($first)) 'a failed second-file acquisition releases the first file'
            $writer.Dispose(); $writer = $null
            $lease = & $module { param($Paths) Open-CcodOfficialDraftEvidenceReadLease -Paths $Paths } @($first,$second)
            [IO.File]::WriteAllText((Join-Path $root 'unrelated-sibling.txt'),'allowed sibling mutation')
            & $module { param($Lease) Assert-CcodOfficialDraftEvidenceReadLease -Lease $Lease } $lease
            $blocked = $false
            try { [IO.File]::WriteAllText($first,'must not replace held bytes') } catch [IO.IOException] { $blocked = $true }
            Assert-CcodTrue $blocked 'successful read authority excludes concurrent data writers'
            & $module { param($Lease) Close-CcodOfficialDraftEvidenceReadLease -Lease $Lease } $lease
            Assert-CcodTrue $lease.Closed 'read lease records closure'
            [IO.File]::WriteAllText($first,'first after release')
            [IO.File]::WriteAllText($second,'second after release')
            Assert-CcodEqual 'second after release' ([IO.File]::ReadAllText($second)) 'all evidence files become writable after release'
        } finally {
            if ($null -ne $writer) { $writer.Dispose() }
            if ($null -ne $lease -and $null -ne $module) { & $module { param($Lease) Close-CcodOfficialDraftEvidenceReadLease -Lease $Lease } $lease }
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'manual artifact copy rejects changed bytes before publication and removes its own residue' {
        foreach ($changedKind in @('Screenshot','RedactedLog')) {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-artifact-copy-change-' + [guid]::NewGuid().ToString('N'))
            $module = $null
            try {
                [IO.Directory]::CreateDirectory($root) | Out-Null
                $screenshot = Join-Path $root 'source-image.bin'
                $log = Join-Path $root 'source.log'
                [IO.File]::WriteAllText($screenshot,'original screenshot bytes',[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($log,'original redacted log bytes',[Text.UTF8Encoding]::new($false))
                $screenshotHash = Get-CcodTestFileSha256 $screenshot
                $logHash = Get-CcodTestFileSha256 $log
                $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
                $write = {
                    param($Destination)
                    & $module {
                        param($Directory,$Image,$Log,$ImageHash,$LogHash)
                        Write-CcodOfficialDraftManualArtifacts -ArtifactDirectory $Directory -Operation About -ScreenshotPath $Image -RedactedLogPath $Log -ExpectedScreenshotSha256 $ImageHash -ExpectedRedactedLogSha256 $LogHash
                    } $Destination $screenshot $log $screenshotHash $logHash
                }
                $control = & $write (Join-Path $root 'control')
                Assert-CcodEqual $screenshotHash (Get-CcodTestFileSha256 $control.Screenshot) 'unmodified copy control publishes the checked screenshot'
                Assert-CcodEqual $logHash (Get-CcodTestFileSha256 $control.RedactedLog) 'unmodified copy control publishes the checked log'
                $changedPath = if ($changedKind -ceq 'Screenshot') { $screenshot } else { $log }
                [IO.File]::WriteAllText($changedPath,'bytes changed after caller hashing',[Text.UTF8Encoding]::new($false))
                $destination = Join-Path $root 'changed'
                Assert-CcodThrows { & $write $destination | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
                Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $destination -Recurse -File).Count 'hash mismatch leaves no temporary or published file owned by this attempt'
                [IO.File]::WriteAllText($screenshot,'original screenshot bytes',[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($log,'original redacted log bytes',[Text.UTF8Encoding]::new($false))
                $retry = & $write $destination
                Assert-CcodEqual $screenshotHash (Get-CcodTestFileSha256 $retry.Screenshot) 'a clean retry is not blocked by failed-copy residue'
                Assert-CcodEqual $logHash (Get-CcodTestFileSha256 $retry.RedactedLog) 'retry log retains the originally checked bytes'
            } finally {
                if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            }
        }
    }

    Invoke-CcodTest 'official draft remote proof binds the current acceptance challenge' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-remote-proof-' + [guid]::NewGuid().ToString('N'))
        $proofPath = Join-Path $root 'remote-proof.json'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $proofTimestamp = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)
        $proof = [ordered]@{ schemaVersion = 1; timestampUtc = $proofTimestamp; kind = 'remote-control-manual-proof'; operation = 'SecondDeviceControl'; deviceRole = 'SecondDevice'; challenge = 'run-1'; candidateVersion = '2.5.22'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64); attestation = 'HumanReviewedStructuredAttestation'; connection = 'Connected'; control = 'Completed'; outcome = 'Completed'; code = 'CCOD_REMOTE_ACTION_COMPLETED' }
        [IO.File]::WriteAllText($proofPath, (($proof | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $parsed = &$module { param($Path) Get-CcodOfficialDraftRemoteProof -Path $Path -ExpectedChallenge 'run-1' -NotBefore ([DateTimeOffset]::UtcNow) -ExpectedVersion '2.5.22' -ExpectedRuntimeId 'runtime-2.5.22' -ExpectedGeneration ([UInt64]2) -ExpectedManifestSha256 ('d' * 64) } $proofPath
            Assert-CcodEqual 'run-1' ([string]$parsed.challenge) 'remote proof binds the current challenge'
            $proof.challenge = 'run-2'
            [IO.File]::WriteAllText($proofPath, (($proof | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { &$module { param($Path) Get-CcodOfficialDraftRemoteProof -Path $Path -ExpectedChallenge 'run-1' -NotBefore ([DateTimeOffset]::UtcNow) -ExpectedVersion '2.5.22' -ExpectedRuntimeId 'runtime-2.5.22' -ExpectedGeneration ([UInt64]2) -ExpectedManifestSha256 ('d' * 64) } $proofPath | Out-Null } 'CCOD_ACCEPTANCE_REMOTE_UNPROVEN'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default adapters use the isolated installed-lifecycle integration contract' {
        $assetNames = @(
            'CodexRemote-fix-2.5.21-windows-x64.zip',
            'CodexRemote-fix-2.5.21-windows-x64.zip.sha256.txt',
            'CodexRemote-fix-2.5.21-trayhost-provenance.json',
            'CodexRemote-fix-2.5.21-payload-manifest.json',
            'CodexRemote-fix-2.5.21-release-manifest.json',
            'CodexRemote-fix-2.5.21-setup.exe',
            'CodexRemote-fix-2.5.21-setup.exe.sha256.txt',
            'CodexRemote-fix-2.5.21-setup-provenance.json',
            'CodexRemote-fix-2.5.21-setup-payload-manifest.json',
            'CodexRemote-fix-2.5.21-setup-destination-inventory.iss',
            'CodexRemote-fix-2.5.21-setup-release-manifest.json'
        )
        $assetState = [pscustomobject]@{ Contract = [pscustomobject][ordered]@{
            Valid = $true; Version = '2.5.21'; GitCommit = ('b' * 40)
            Assets = @($assetNames | ForEach-Object { [pscustomobject][ordered]@{ name = $_; sha256 = ('a' * 64) } })
        } }
        $fakeAssetModule = New-Module -ArgumentList $assetState, $assetNames -ScriptBlock {
            param($State,$Names)
            function Get-CcodExpectedReleaseAssetNames { param($Version); return @($Names | ForEach-Object { $_ -replace '2\.5\.21', [string]$Version }) }
            function Test-CcodExactReleaseAssetSet { param($AssetDirectory,$Version); return $State.Contract }
            Export-ModuleMember -Function Get-CcodExpectedReleaseAssetNames,Test-CcodExactReleaseAssetSet
        }
        $integrationState = [pscustomobject]@{
            PreviousCalls = 0
            FactsCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[object]]::new()
            Facts = [pscustomobject][ordered]@{
                installRootPresent = $true
                appPresent = $true
                runtimeRootPresent = $true
                activePointerPresent = $true
                activeRuntimeId = 'runtime-2.5.22'
                activeGeneration = [UInt64]2
                runtimeManifestSha256 = ('d' * 64)
                supervisor = @([pscustomobject]@{ pid = 200; creationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
                trayHost = @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
                codex = @([pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }); codexCount = 1
                taskState = 'Ready'
                statusPhase = 'Active'
                statusRuntimeId = 'runtime-2.5.22'
                statusCodex = [pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
                transitionStage = 'Idle'
                lifecycleReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; phase = 'Completed' }
                shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
            debugEndpoints = @([pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' },[pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' })
            debugPorts = @(9229,9230)
                aboutVersion = $null
                deviceKeyPresent = $true
                deviceKeySha256 = ('b' * 64)
            }
        }
        $fakeIntegrationModule = New-Module -ArgumentList $integrationState -ScriptBlock {
            param($State)
            function Get-CcodInstalledLifecycleFacts {
                param($InstallRoot,$ExpectedVersion)
                $State.FactsCalls.Add([string]$InstallRoot)
                return $State.Facts
            }
            function Invoke-CcodInstalledLifecycleIntegration {
                param($InstallerPath,$PreviousInstallerPath,$PreviousExpectedVersion,$PreviousInstallerSha256,$PreviousManifestSha256,$ExpectedVersion,$EvidenceRoot,$AllowMachineMutation,$AllowCodexRestart,$Scenario)
                $State.RunCalls.Add([pscustomobject][ordered]@{
                    InstallerPath = $InstallerPath; PreviousInstallerPath = $PreviousInstallerPath; PreviousExpectedVersion = $PreviousExpectedVersion; PreviousInstallerSha256 = $PreviousInstallerSha256; PreviousManifestSha256 = $PreviousManifestSha256; ExpectedVersion = $ExpectedVersion
                    EvidenceRoot = $EvidenceRoot; AllowMachineMutation = [bool]$AllowMachineMutation; AllowCodexRestart = [bool]$AllowCodexRestart; Scenario = $Scenario
                })
                return [pscustomobject][ordered]@{ outcome = 'Completed'; installerSha256 = ('c' * 64); verification = [pscustomobject][ordered]@{ verified = $true; facts = [pscustomobject][ordered]@{ runtimeManifestSha256 = ('d' * 64) } } }
            }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts,Invoke-CcodInstalledLifecycleIntegration
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $observed = &$module {
                param($FakeAsset,$FakeIntegration)
                $script:CcodOfficialDraftAssetModule = $FakeAsset
                $script:CcodOfficialDraftIntegrationModule = $FakeIntegration
                $candidate = [pscustomobject][ordered]@{ version = '2.5.22'; assetHashes = @([pscustomobject][ordered]@{ name = 'CodexRemote-fix-2.5.22-setup.exe'; sha256 = ('c' * 64) }) }
                $draft = [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = '123' }
                $previousSetup = [pscustomobject][ordered]@{ version = '2.5.21'; gitCommit = ('b' * 40); assetSha256 = ('a' * 64); manifestSha256 = ('a' * 64) }
                $context = New-CcodOfficialDraftContext -Phase 'LegacyUpgrade' -AssetDirectory 'C:\candidate' -PreviousAssetDirectory 'C:\previous' -EvidenceRoot 'C:\evidence' -Candidate $candidate -Draft $draft -PreviousSetup $previousSetup -AllowMachineMutation -AllowCodexRestart
                $defaults = Get-CcodOfficialDraftDefaultAdapters
                $run = & $defaults.RunPhase $context
                $facts = & $defaults.CaptureFacts $context 'After'
                [pscustomobject][ordered]@{ Context = $context; Run = $run; Facts = $facts }
            } $fakeAssetModule $fakeIntegrationModule
            Assert-CcodEqual 'Upgrade' ([string]$integrationState.RunCalls[0].Scenario) 'default LegacyUpgrade maps to the integration Upgrade scenario'
            Assert-CcodEqual ([string]$observed.Context.setupPath) ([string]$integrationState.RunCalls[0].InstallerPath) 'default phase passes the candidate Setup path'
            Assert-CcodEqual ([string]$observed.Context.previousSetupPath) ([string]$integrationState.RunCalls[0].PreviousInstallerPath) 'default upgrade passes the previous Setup path'
            Assert-CcodEqual '2.5.21' ([string]$integrationState.RunCalls[0].PreviousExpectedVersion) 'default upgrade passes the validated previous version'
            Assert-CcodEqual ('a' * 64) ([string]$integrationState.RunCalls[0].PreviousInstallerSha256) 'default upgrade passes the validated previous Setup hash'
            Assert-CcodEqual ('a' * 64) ([string]$integrationState.RunCalls[0].PreviousManifestSha256) 'default upgrade passes the validated previous manifest hash'
            Assert-CcodEqual '2.5.22' ([string]$observed.Context.expectedVersion) 'core context binds the candidate version'
            Assert-CcodEqual '2.5.22' ([string]$integrationState.RunCalls[0].ExpectedVersion) 'default phase passes the candidate version'
            Assert-CcodEqual 1 $integrationState.FactsCalls.Count 'default facts adapter captures through the integration module'
            Assert-CcodTrue ([bool]$observed.Facts.appRootPresent) 'default facts preserve the installed app observation'
        } finally {
            if ($null -ne $fakeIntegrationModule) { Remove-Module -Name $fakeIntegrationModule.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeAssetModule) { Remove-Module -Name $fakeAssetModule.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default remote adapter passes candidate-bound lifecycle observation arguments' {
        $source = [IO.File]::ReadAllText($modulePath)
        Assert-CcodTrue ($source.Contains('Get-CcodInstalledLifecycleFacts -InstallRoot $Root -ExpectedVersion $Version -ExpectedDebugPorts ([int[]]$DebugPorts)')) 'default remote adapter binds the candidate version and complete expected debug-port set'
        Assert-CcodTrue ($source.Contains('$facts.activeRuntimeId -cne [string]$readyAfter.activeRuntimeId')) 'default remote adapter binds the active runtime to the ready-after identity'
        Assert-CcodTrue ($source.Contains('[UInt64]$facts.activeGeneration -ne [UInt64]$readyAfter.activeGeneration')) 'default remote adapter binds the active generation to the ready-after identity'
        Assert-CcodTrue ($source.Contains('ExpectedDeviceKeySha256')) 'manual readiness accepts the persisted device-key expectation'
        Assert-CcodTrue ($source.Contains('$facts.deviceKeySha256 -cne $ExpectedDeviceKeySha256')) 'manual readiness binds the device key to the persisted acceptance state'
        Assert-CcodTrue ($source.Contains('$readyAfterCodex')) 'remote evidence binds endpoints to the ready-after Codex identity'
    }

    Invoke-CcodTest 'official draft Complete rejects missing bounded manual evidence' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts -BootId 'boot-1')
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            $state.BootId = 'boot-2'; $state.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
            Invoke-CcodAcceptancePrivate -Phase PostReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            Invoke-CcodAcceptancePrivate -Phase ReadyForManualEvidence -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INCOMPLETE'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft manual proof rejects a stale redacted action log' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-stale-redacted-log-' + [guid]::NewGuid().ToString('N'))
        $logs = Join-Path $root 'logs'
        $redacted = Join-Path $root 'redacted.log'
        $screenshot = Join-Path $root 'screenshot.bin'
        [IO.Directory]::CreateDirectory((Join-Path $root 'runtime')) | Out-Null
        [IO.Directory]::CreateDirectory($logs) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($screenshot,'fixture screenshot',[Text.UTF8Encoding]::new($false))
        $future = [DateTimeOffset]::UtcNow.AddMinutes(1).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $ready = [ordered]@{ schemaVersion = 1; timestampUtc = $future; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2 }
        $base = [ordered]@{ schemaVersion = 1; timestampUtc = $future; component = 'Supervisor'; stage = 'TrayAction'; code = 'CCOD_TRAY_ACTION_COMPLETED'; outcome = 'Completed'; command = 'ShowAbout'; revision = 7; status = 'Completed' }
        [IO.File]::WriteAllText((Join-Path $logs 'supervisor.log'), (($ready | ConvertTo-Json -Compress) + "`n" + ($base | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $stale = [ordered]@{}
        foreach ($entry in $base.GetEnumerator()) { $stale[$entry.Key] = $entry.Value }
        $stale.timestampUtc = '2000-01-01T00:00:00.0000000Z'
        [IO.File]::WriteAllText($redacted, (($base | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $facts = [pscustomobject][ordered]@{
            installRootPresent = $true; appPresent = $true; runtimeRootPresent = $true; activePointerPresent = $true; activeRuntimeId = 'runtime-2.5.22'; activeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64)
            supervisor = @([pscustomobject]@{ pid = 200; creationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
            trayHost = @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }
            codex = @([pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }); codexCount = 1
            trayAuthenticated = $true
            taskState = 'Ready'; statusPhase = 'Active'; statusRuntimeId = 'runtime-2.5.22'
            statusCodex = [pscustomobject]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            transitionStage = 'Idle'; lifecycleReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; phase = 'Completed' }
            aboutVersion = '2.5.22'; deviceKeyPresent = $true; deviceKeySha256 = ('b' * 64)
            shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
            debugEndpoints = @([pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' },[pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' })
            debugPorts = @(9229,9230)
        }
        $state = [pscustomobject]@{ Facts = $facts; Calls = 0; ProofReads = 0; LiveProofReads = 0; Target = $redacted; LivePath = (Join-Path $logs 'supervisor.log') }
        $fakeIntegration = New-Module -ArgumentList $state -ScriptBlock {
            param($State)
            function Get-CcodInstalledLifecycleFacts { param($InstallRoot,$ExpectedVersion) $State.Calls++; return $State.Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $run = & $module {
                param($Fake,$InstallRoot,$State)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $script:CcodStaleProofState = $State
                $script:CcodStaleProofOriginal = ${function:Get-CcodOfficialDraftJsonLines}
                function script:Get-CcodOfficialDraftJsonLines {
                    param([string]$Path,[AllowNull()][Nullable[DateTimeOffset]]$NotBefore)
                    if ($Path -ceq $script:CcodStaleProofState.Target) { $script:CcodStaleProofState.ProofReads++ }
                    if ($Path -ceq $script:CcodStaleProofState.LivePath -and $null -ne $NotBefore) { $script:CcodStaleProofState.LiveProofReads++ }
                    & $script:CcodStaleProofOriginal -Path $Path -NotBefore $NotBefore
                }
                (Get-CcodOfficialDraftDefaultAdapters).RunManualOperation
            } $fakeIntegration $root $state
            $context = [pscustomobject][ordered]@{ screenshotPath = $screenshot; redactedLogPath = $redacted; expectedVersion = '2.5.22'; manualAcknowledgement = 'CCOD_MANUAL_ABOUT_COMPLETED' }
            $positive = & $run $context 'About'
            Assert-CcodTrue $positive.verified 'complete fresh manual proof is accepted before the timestamp-only mutation'
            $previousReads = $state.ProofReads
            $previousFacts = $state.Calls
            [IO.File]::WriteAllText($redacted, (($stale | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { & $run $context 'About' | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN'
            Assert-CcodEqual ($previousReads + 1) $state.ProofReads 'stale case reaches the real redacted proof parser'
            Assert-CcodEqual ($previousFacts + 2) $state.Calls 'stale case has passed both readiness observations'
            # Matching old live/redacted records must still fail freshness, not only tuple equality.
            [IO.File]::WriteAllText($state.LivePath, (($ready | ConvertTo-Json -Compress) + "`n" + ($stale | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
            $previousLiveReads = $state.LiveProofReads
            $previousFacts = $state.Calls
            Assert-CcodThrows { & $run $context 'About' | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN'
            Assert-CcodEqual ($previousLiveReads + 1) $state.LiveProofReads 'matching stale records reach freshness validation in the live proof parser'
            Assert-CcodEqual ($previousFacts + 2) $state.Calls 'matching stale action records do not invalidate current host readiness'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft manual proof rechecks current ready runtime state' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-manual-readiness-' + [guid]::NewGuid().ToString('N'))
        $logs = Join-Path $root 'logs'
        $redacted = Join-Path $root 'redacted.log'
        $screenshot = Join-Path $root 'screenshot.bin'
        [IO.Directory]::CreateDirectory($logs) | Out-Null
        [IO.File]::WriteAllText($screenshot,'fixture screenshot',[Text.UTF8Encoding]::new($false))
        $future = [DateTimeOffset]::UtcNow.AddMinutes(1).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $record = [ordered]@{
            schemaVersion = 1; timestampUtc = $future; component = 'Supervisor'; stage = 'TrayAction'
            code = 'CCOD_TRAY_ACTION_COMPLETED'; outcome = 'Completed'; command = 'ShowAbout'; revision = 7; status = 'Completed'
        }
        $json = (($record | ConvertTo-Json -Compress) + "`n")
        $ready = [ordered]@{ schemaVersion = 1; timestampUtc = $future; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = 7 }
        [IO.File]::WriteAllText((Join-Path $logs 'supervisor.log'), (($ready | ConvertTo-Json -Compress) + "`n" + $json), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($redacted, $json, [Text.UTF8Encoding]::new($false))
        $facts = New-CcodAcceptanceFacts
        $facts | Add-Member -NotePropertyName appPresent -NotePropertyValue $true
        $state = [pscustomobject]@{ Facts = $facts; Calls = 0; DriftAt = 0 }
        $fakeIntegration = New-Module -ArgumentList $state -ScriptBlock {
            param($State)
            function Get-CcodInstalledLifecycleFacts {
                param($InstallRoot,$ExpectedVersion)
                $State.Calls++
                $observed = $State.Facts.PSObject.Copy()
                if ($State.DriftAt -gt 0 -and $State.Calls -ge $State.DriftAt) { $observed.aboutVersion = '2.5.21' }
                return $observed
            }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $run = & $module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                (Get-CcodOfficialDraftDefaultAdapters).RunManualOperation
            } $fakeIntegration $root
            $context = [pscustomobject][ordered]@{ screenshotPath = $screenshot; redactedLogPath = $redacted; expectedVersion = '2.5.22'; manualAcknowledgement = 'CCOD_MANUAL_ABOUT_COMPLETED' }
            $positive = & $run $context 'About'
            Assert-CcodTrue $positive.verified 'complete ready baseline succeeds before observation drift'
            $previousCalls = $state.Calls
            $state.DriftAt = $previousCalls + 2
            Assert-CcodThrows { & $run $context 'About' | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN'
            Assert-CcodEqual ($previousCalls + 2) $state.Calls 'readiness is reobserved after acknowledgement, not rejected at context validation'
            Assert-CcodEqual '2.5.22' $state.Facts.aboutVersion 'the initial healthy fixture remains unchanged'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft preserves an inner acceptance error from post-manual observation' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        [IO.Directory]::CreateDirectory($manualRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            $originalCapture = $adapters.CaptureFacts
            $adapters.CaptureFacts = {
                param($Context,$Point)
                try {
                    if ([string]$Point -ceq 'AfterManualOperation') {
                        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList 'inner acceptance fixture error'
                        Write-Error -Exception $exception -ErrorId 'CCOD_ACCEPTANCE_TEST_INNER' -Category InvalidData -ErrorAction Stop
                    }
                    & $originalCapture $Context $Point
                } catch { $State.InnerErrorId = [string]$_.FullyQualifiedErrorId; throw }
            }.GetNewClosure()
            $state | Add-Member -NotePropertyName InnerErrorId -NotePropertyValue $null -Force
            $observedErrorId = $null
            try {
                Invoke-CcodAcceptancePrivate -Phase TrayEvidence -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -TrayOperation About -ScreenshotPath $paths.About.Screenshot -RedactedLogPath $paths.About.Log -ReviewState Reviewed | Out-Null
            } catch { $observedErrorId = [string]$_.FullyQualifiedErrorId }
            if ($state.InnerErrorId -notlike 'CCOD_ACCEPTANCE_TEST_INNER*') { throw "adapter inner error id was [$($state.InnerErrorId)]" }
            Assert-CcodEqual 'CCOD_ACCEPTANCE_TEST_INNER' $observedErrorId 'post-manual observation preserves the inner acceptance error id'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft records four tray operations and second-device evidence before Complete' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        [IO.Directory]::CreateDirectory($manualRoot) | Out-Null
        $state = [pscustomobject]@{
            DefenderCalls = [Collections.Generic.List[string]]::new()
            RunCalls = [Collections.Generic.List[string]]::new()
            CaptureCalls = [Collections.Generic.List[string]]::new()
            BootCalls = 0; RebootCalls = 0; PreviousCalls = 0
            BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = (New-CcodAcceptanceFacts -BootId 'boot-1')
        }
        $operations = @('About','Language','OpenLogs','Repair','SecondDeviceControl')
        $paths = @{}
        foreach ($operation in $operations) {
            $paths[$operation] = [pscustomobject][ordered]@{
                Screenshot = Join-Path $manualRoot ($operation + '-screenshot.png')
                Log = Join-Path $manualRoot ($operation + '-redacted.log')
            }
            [IO.File]::WriteAllText($paths[$operation].Screenshot, 'screenshot-' + $operation, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($paths[$operation].Log, 'redacted-log-' + $operation, [Text.UTF8Encoding]::new($false))
        }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            $state.BootId = 'boot-2'; $state.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
            Invoke-CcodAcceptancePrivate -Phase PostReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            Invoke-CcodAcceptancePrivate -Phase ReadyForManualEvidence -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            $normalManualOperation = $adapters.RunManualOperation
            $adapters.RunManualOperation = {
                param($Context,$Operation)
                $State.Facts.bootId = 'boot-detached'
                return & $normalManualOperation $Context $Operation
            }.GetNewClosure()
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase TrayEvidence -TrayOperation 'About' -ScreenshotPath $paths.About.Screenshot -RedactedLogPath $paths.About.Log -ReviewState Reviewed -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN'
            $adapters.RunManualOperation = $normalManualOperation
            $state.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
            foreach ($operation in @('About','Language','OpenLogs','Repair')) {
                Invoke-CcodAcceptancePrivate -Phase TrayEvidence -TrayOperation $operation -ScreenshotPath $paths[$operation].Screenshot -RedactedLogPath $paths[$operation].Log -ReviewState Reviewed -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            }
            Invoke-CcodAcceptancePrivate -Phase RemoteEvidence -RemoteOperation SecondDeviceControl -ScreenshotPath $paths.SecondDeviceControl.Screenshot -RedactedLogPath $paths.SecondDeviceControl.Log -ReviewState Reviewed -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            $aboutArtifact = Join-Path (Join-Path (Join-Path $evidenceRoot 'official-draft-artifacts') 'About') 'screenshot.bin'
            [IO.File]::WriteAllText($aboutArtifact, 'tampered-artifact', [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            $restoreBytes = [IO.File]::ReadAllBytes($paths['About'].Screenshot)
            [IO.File]::Delete($aboutArtifact)
            [IO.File]::WriteAllBytes($aboutArtifact, $restoreBytes)
            $normalClock = $adapters.GetUtcNow
            $adapters.GetUtcNow = { return [datetime]::SpecifyKind([datetime]::Parse('2030-02-03T04:05:06'), [DateTimeKind]::Unspecified) }
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_COMPLETE_WRITE_FAILED'
            $adapters.GetUtcNow = $normalClock
            $complete = Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            Assert-CcodEqual 'Complete' ([string]$complete.phase) 'complete returns its canonical phase'
            Assert-CcodTrue ([bool]$complete.complete) 'complete reports the complete gate only after all five records'
            $manualDirectory = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') 'manual-evidence'
            Assert-CcodEqual 5 (@(Get-ChildItem -LiteralPath $manualDirectory -File).Count) 'complete retains exactly five bounded manual records'
            $completePath = Join-Path (Join-Path $evidenceRoot 'acceptance') 'CodexRemote-fix-2.5.22-official-draft.complete.json'
            Assert-CcodTrue (Test-Path -LiteralPath $completePath -PathType Leaf) 'complete writes the Promote acceptance receipt'
            $serialized = [IO.File]::ReadAllText($completePath)
            $completeReceipt = $serialized | ConvertFrom-Json
            Assert-CcodEqual 'v2.5.22' ([string]$completeReceipt.draft.tag) 'complete receipt records the draft tag'
            Assert-CcodEqual '123' ([string]$completeReceipt.draft.id) 'complete receipt records the draft identifier'
            $remoteRecord = @($completeReceipt.manualEvidence | Where-Object { $_.operation -ceq 'SecondDeviceControl' })
            Assert-CcodTrue ($remoteRecord.Count -eq 1 -and $null -ne $remoteRecord[0].proof -and [string]$remoteRecord[0].proof.candidateVersion -ceq '2.5.22' -and -not [string]::IsNullOrWhiteSpace([string]$remoteRecord[0].proof.challenge)) 'complete receipt preserves the structured second-device proof'
            $freshReceipt = ([IO.File]::ReadAllText((Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '04-FreshInstall.json')) | ConvertFrom-Json)
            $postReceipt = ([IO.File]::ReadAllText((Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '06-PostReboot.json')) | ConvertFrom-Json)
            Assert-CcodTrue ($null -ne $freshReceipt.facts.trayHostIdentity -and $null -ne $postReceipt.facts.trayHostIdentity) 'automated receipts persist the exact TrayHost identity'
            foreach ($path in @($paths.About.Screenshot,$paths.About.Log,$paths.SecondDeviceControl.Screenshot,$paths.SecondDeviceControl.Log)) {
                Assert-CcodTrue (-not $serialized.Contains($path)) 'complete receipt does not persist private evidence paths'
            }
            Assert-CcodEqual 5 (@($complete.facts.manualEvidence).Count) 'complete result contains all five normalized records'
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            } 'CCOD_ACCEPTANCE_PHASE_REUSED'
            $stateDirectory = Join-Path $evidenceRoot 'official-draft-acceptance'
            $completeStatePath = Join-Path $stateDirectory '08-Complete.json'
            $manualStatePath = Join-Path (Join-Path $stateDirectory 'manual-evidence') 'RemoteEvidence-SecondDeviceControl.json'
            $completeState = [IO.File]::ReadAllText($completeStatePath) | ConvertFrom-Json
            $manualState = [IO.File]::ReadAllText($manualStatePath) | ConvertFrom-Json
            $completeRemote = @($completeState.facts.manualEvidence | Where-Object { $_.operation -ceq 'SecondDeviceControl' })[0]
            $completeRemote.proof.candidateVersion = '2.5.21'
            $completeRemote.proof.challenge = 'tampered-challenge'
            $manualState.proof.candidateVersion = '2.5.21'
            $manualState.proof.challenge = 'tampered-challenge'
            [IO.File]::WriteAllText($completeStatePath, ($completeState | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($manualStatePath, ($manualState | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            $stateModule = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                Assert-CcodThrows {
                    &$stateModule {
                        param($Directory)
                        $records = Read-CcodOfficialDraftState -StateDirectory $Directory
                        [void](Assert-CcodOfficialDraftAutomatedReceiptChain -Records $records -StateDirectory $Directory)
                    } $stateDirectory
                } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            } finally {
                if ($null -ne $stateModule) { Remove-Module -Name $stateModule.Name -Force -ErrorAction SilentlyContinue }
            }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft rejects a candidate change after ReadyForManualEvidence' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $fixture.Contract.GitCommit = 'd' * 40
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase TrayEvidence -TrayOperation About -ScreenshotPath $paths.About.Screenshot -RedactedLogPath $paths.About.Log -ReviewState Reviewed -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_CANDIDATE_CHANGED'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft manual evidence requires every automated receipt after Ready' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            Remove-Item -LiteralPath (Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '06-PostReboot.json') -Force
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase TrayEvidence -TrayOperation About -ScreenshotPath $paths.About.Screenshot -RedactedLogPath $paths.About.Log -ReviewState Reviewed -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_PHASE_ORDER_INVALID'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft rejects manual evidence seeded before ReadyForManualEvidence' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $stateDirectory = Join-Path $evidenceRoot 'official-draft-acceptance'
        $manualDirectory = Join-Path $stateDirectory 'manual-evidence'
        [IO.Directory]::CreateDirectory($manualDirectory) | Out-Null
        $record = [ordered]@{ schemaVersion = 1; kind = 'manual-evidence'; phase = 'TrayEvidence'; operation = 'About'; terminalState = 'AboutVisible'; result = 'CCOD_TRAYABOUT_COMPLETED'; proof = [ordered]@{ timestampUtc = '2030-02-03T04:05:06.0000000Z'; command = 'ShowAbout'; revision = 1; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }; reviewState = 'Reviewed'; version = '2.5.22'; gitCommit = $fixture.GitCommit; candidateManifestSha256 = $fixture.Contract.PortableManifestSha256; screenshotSha256 = ('1' * 64); redactedLogSha256 = ('2' * 64) }
        [IO.File]::WriteAllText((Join-Path $manualDirectory 'TrayEvidence-About.json'), (($record | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_EARLY'
            Assert-CcodEqual 0 $state.DefenderCalls.Count 'pre-seeded manual evidence blocks Defender work before automation'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft Complete does not leave a terminal state when acceptance target already exists' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Invoke-CcodAcceptanceManualRecords -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -Paths $paths
            $acceptanceDirectory = Join-Path $evidenceRoot 'acceptance'
            [IO.Directory]::CreateDirectory($acceptanceDirectory) | Out-Null
            $acceptancePath = Join-Path $acceptanceDirectory 'CodexRemote-fix-2.5.22-official-draft.complete.json'
            [IO.File]::WriteAllText($acceptancePath, 'existing', [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_PHASE_REUSED'
            Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '08-Complete.json') -PathType Leaf)) 'failed Complete does not leave an unusable terminal state'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'Complete rejects an interleaved contender without invalidating its successful receipt chain' {
        $fixture=New-CcodAcceptanceCandidateFixture
        $previousRoot=Join-Path ([IO.Path]::GetTempPath()) ('ccod-complete-interleave-'+[guid]::NewGuid().ToString('N'))
        $evidenceRoot=Join-Path $fixture.Root 'evidence';$manualRoot=Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot)|Out-Null;[IO.Directory]::CreateDirectory($evidenceRoot)|Out-Null
        $state=[pscustomobject]@{DefenderCalls=[Collections.Generic.List[string]]::new();RunCalls=[Collections.Generic.List[string]]::new();CaptureCalls=[Collections.Generic.List[string]]::new();BootCalls=0;RebootCalls=0;PreviousCalls=0;BootId='boot-1';KeyHash=('b'*64);Facts=New-CcodAcceptanceFacts}
        $module=$null
        try {
            $adapters=New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths=New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Invoke-CcodAcceptanceManualRecords -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -Paths $paths
            $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $probe=[pscustomobject]@{Attempts=0;InnerError=$null;InnerResult=$null;OuterError=$null;OuterResult=$null;InnerValidation=0}
            $contender=$adapters.Clone();$validate=$contender.ValidateAssetSet
            $contender.ValidateAssetSet={param($Path,$Version)$probe.InnerValidation++;&$validate $Path $Version}.GetNewClosure()
            $clock=$adapters.GetUtcNow
            $adapters.GetUtcNow={
                $probe.Attempts++
                try{$probe.InnerResult=&$module {param($A,$P,$E,$Adapters)Invoke-CcodOfficialDraftAcceptanceCore -Phase Complete -AssetDirectory $A -PreviousAssetDirectory $P -EvidenceRoot $E -DraftId '123' -Adapters $Adapters} $fixture.Root $previousRoot $evidenceRoot $contender}catch{$probe.InnerError=$_.FullyQualifiedErrorId}
                return &$clock
            }.GetNewClosure()
            try{$probe.OuterResult=&$module {param($A,$P,$E,$Adapters)Invoke-CcodOfficialDraftAcceptanceCore -Phase Complete -AssetDirectory $A -PreviousAssetDirectory $P -EvidenceRoot $E -DraftId '123' -Adapters $Adapters} $fixture.Root $previousRoot $evidenceRoot $adapters}catch{$probe.OuterError=$_.FullyQualifiedErrorId}
            Assert-CcodEqual 1 $probe.Attempts 'contender runs after the outer call validated its initial state'
            Assert-CcodTrue ($probe.InnerError-like'CCOD_ACCEPTANCE_OPERATION_BUSY*') 'same evidence root rejects the contender before any operation'
            Assert-CcodEqual 0 $probe.InnerValidation 'busy rejection precedes candidate/default adapter side effects'
            Assert-CcodEqual $null $probe.OuterError 'the original operation is not poisoned by its rejected contender'
            Assert-CcodTrue $probe.OuterResult.complete 'original Complete returns success'
            $statePath=Join-Path $evidenceRoot 'official-draft-acceptance\08-Complete.json'
            $acceptancePath=Join-Path $evidenceRoot 'acceptance\CodexRemote-fix-2.5.22-official-draft.complete.json'
            $persisted=[IO.File]::ReadAllText($acceptancePath)|ConvertFrom-Json
            Assert-CcodEqual (Get-CcodTestFileSha256 $statePath) (@($persisted.automatedReceiptSha256|Where-Object {$_.phase-ceq'Complete'})[0].sha256) 'successful aggregate remains linked to its durable Complete state'
            & $module {param($Root) $records=Read-CcodOfficialDraftState -StateDirectory (Join-Path $Root 'official-draft-acceptance');Assert-CcodOfficialDraftAutomatedReceiptChain -Records $records -StateDirectory (Join-Path $Root 'official-draft-acceptance')|Out-Null} $evidenceRoot
        } finally {if($null-ne$module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue};if(Test-Path $fixture.Root){Remove-Item $fixture.Root -Recurse -Force};if(Test-Path $previousRoot){Remove-Item $previousRoot -Recurse -Force}}
    }

    Invoke-CcodTest 'acceptance operation authority is exclusive across imports and native child processes' {
        $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-op-lock-'+[guid]::NewGuid().ToString('N'))
        $module=$null;$first=$null;$second=$null;$process=$null
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $evidence=Join-Path $root 'evidence';$other=Join-Path $root 'other';[IO.Directory]::CreateDirectory($evidence)|Out-Null;[IO.Directory]::CreateDirectory($other)|Out-Null
        try {
            $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
            $first=&$module {param($Root) Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $evidence
            Assert-CcodThrows {&$module {param($Root) Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $evidence|Out-Null} 'CCOD_ACCEPTANCE_OPERATION_BUSY'
            $second=&$module {param($Root) Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $other
            &$module {param($Lease) Close-CcodOfficialDraftOperationLease $Lease} $second;$second=$null
            &$module {param($Lease) Close-CcodOfficialDraftOperationLease $Lease} $first;$first=$null
            $child=Join-Path $root 'hold-lock.ps1'
            $text=@'
param([string]$ModulePath,[string]$Root)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$module=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
$lease=$null
try {
 $lease=&$module {param($Root)Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $Root
 [Console]::WriteLine('CCOD_OPERATION_LEASE_HELD');[Console]::Out.Flush()
 [void][Console]::ReadLine()
} finally {if($null-ne$lease){&$module {param($Lease)Close-CcodOfficialDraftOperationLease $Lease} $lease}}
'@
            [IO.File]::WriteAllText($child,$text,[Text.UTF8Encoding]::new($false))
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe'
            $start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$child+'" -ModulePath "'+$modulePath+'" -Root "'+$evidence+'"'
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true;$start.CreateNoWindow=$true
            [void]$start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
            $process=[Diagnostics.Process]::Start($start)
            $errors=$process.StandardError.ReadToEndAsync();$line=$process.StandardOutput.ReadLineAsync()
            Assert-CcodTrue ($line.Wait(15000)) 'normal-policy child reports the real acquired lock without a blind delay'
            Assert-CcodEqual 'CCOD_OPERATION_LEASE_HELD' $line.Result 'child reached actual native lease'
            Remove-Module $module.Name -Force;$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
            Assert-CcodThrows {&$module {param($Root)Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $evidence|Out-Null} 'CCOD_ACCEPTANCE_OPERATION_BUSY'
            Write-CcodTestProcessInput -Process $process -Text 'release' -AddNewLine
            Assert-CcodTrue ($process.WaitForExit(15000)) 'owned inert child exits after explicit release'
            Assert-CcodEqual 0 $process.ExitCode 'child lease release succeeds'
            Assert-CcodEqual '' $errors.Result 'native child has no hidden lock error'
            $first=&$module {param($Root)Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $evidence
            Assert-CcodTrue ($null-ne$first) 'new acquisition after child exit proves release'
            $blocked=$false;try{[IO.Directory]::Move($evidence,$evidence+'.moved')}catch [IO.IOException]{$blocked=$true}
            Assert-CcodTrue $blocked 'held evidence-root authority denies ancestor replacement'
            &$module {param($Lease)Close-CcodOfficialDraftOperationLease $Lease} $first;$first=$null
            $lockPath=Join-Path $evidence '.ccod-official-draft-operation.lock'
            [IO.File]::WriteAllText($lockPath,'foreign lock contents')
            Assert-CcodThrows {&$module {param($Root)Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $evidence|Out-Null} 'CCOD_ACCEPTANCE_OPERATION_LOCK_FAILED'
            Assert-CcodEqual 'foreign lock contents' ([IO.File]::ReadAllText($lockPath)) 'unsafe lock content remains untouched'
            [IO.File]::WriteAllBytes($lockPath,[byte[]]@())
            $first=&$module {param($Root)Open-CcodOfficialDraftOperationLease -EvidenceRoot $Root} $evidence
        } finally {
            if($null-ne$process){if(-not$process.HasExited){$process.StandardInput.Close();if(-not$process.WaitForExit(15000)){$process.Kill();[void]$process.WaitForExit(10000)}};$process.Dispose()}
            foreach($lease in @($second,$first)){if($null-ne$lease){&$module {param($Lease)Close-CcodOfficialDraftOperationLease $Lease} $lease}}
            if($null-ne$module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
            if(Test-Path $root){Remove-Item $root -Recurse -Force}
        }
    }

    Invoke-CcodTest 'failed Complete recovery never adopts deletion ownership of a preexisting state receipt' {
        $fixture=New-CcodAcceptanceCandidateFixture
        $previousRoot=Join-Path ([IO.Path]::GetTempPath()) ('ccod-complete-reuse-'+[guid]::NewGuid().ToString('N'))
        $evidenceRoot=Join-Path $fixture.Root 'evidence';$manualRoot=Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot)|Out-Null;[IO.Directory]::CreateDirectory($evidenceRoot)|Out-Null
        $state=[pscustomobject]@{DefenderCalls=[Collections.Generic.List[string]]::new();RunCalls=[Collections.Generic.List[string]]::new();CaptureCalls=[Collections.Generic.List[string]]::new();BootCalls=0;RebootCalls=0;PreviousCalls=0;BootId='boot-1';KeyHash=('b'*64);Facts=New-CcodAcceptanceFacts}
        try {
            $adapters=New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths=New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Invoke-CcodAcceptanceManualRecords -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -Paths $paths
            $invokeArgs=@{Phase='Complete';AssetDirectory=$fixture.Root;PreviousAssetDirectory=$previousRoot;EvidenceRoot=$evidenceRoot;Adapters=$adapters}
            $control=Invoke-CcodAcceptancePrivate @invokeArgs
            Assert-CcodTrue $control.complete 'full successful control precedes recovery failure'
            $statePath=Join-Path $evidenceRoot 'official-draft-acceptance\08-Complete.json'
            $acceptancePath=Join-Path $evidenceRoot 'acceptance\CodexRemote-fix-2.5.22-official-draft.complete.json'
            $stateHash=Get-CcodTestFileSha256 $statePath
            [IO.File]::Delete($acceptancePath)
            $artifact=Join-Path $evidenceRoot 'official-draft-artifacts\About\screenshot.bin'
            $bytes=[IO.File]::ReadAllBytes($artifact)
            [IO.File]::WriteAllText($artifact,'independent artifact drift')
            Assert-CcodThrows {Invoke-CcodAcceptancePrivate @invokeArgs|Out-Null} 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            Assert-CcodTrue ([IO.File]::Exists($statePath)) 'reused Complete state is not owned by the failed invocation'
            Assert-CcodEqual $stateHash (Get-CcodTestFileSha256 $statePath) 'failed recovery preserves prior terminal evidence bytes'
            Assert-CcodTrue (-not[IO.File]::Exists($acceptancePath)) 'failed recovery does not create a successful aggregate'
            [IO.File]::WriteAllBytes($artifact,$bytes)
            $retry=Invoke-CcodAcceptancePrivate @invokeArgs
            Assert-CcodTrue $retry.complete 'safe existing-state recovery remains retryable after the root cause is corrected'
        } finally {if(Test-Path $fixture.Root){Remove-Item $fixture.Root -Recurse -Force};if(Test-Path $previousRoot){Remove-Item $previousRoot -Recurse -Force}}
    }

    Invoke-CcodTest 'official draft Complete resumes when the terminal state receipt survived without acceptance' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        [IO.Directory]::CreateDirectory($manualRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Invoke-CcodAcceptanceManualRecords -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -Paths $paths
            $stateDirectory = Join-Path $evidenceRoot 'official-draft-acceptance'
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                &$module {
                    param($Directory,$Previous)
                    $records = Read-CcodOfficialDraftState -StateDirectory $Directory -PreviousAssetDirectory $Previous
                    $facts = [pscustomobject][ordered]@{ manualEvidence = @($records.ManualEvidence.Values); status = 'Complete'; complete = $true }
                    Write-CcodOfficialDraftReceipt -StateDirectory $Directory -Phase Complete -Candidate $records.Preflight.candidate -Draft $records.Preflight.draft -Facts $facts | Out-Null
                } $stateDirectory $previousRoot
            } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            $completeState = Join-Path $stateDirectory '08-Complete.json'
            Assert-CcodTrue (Test-Path -LiteralPath $completeState -PathType Leaf) 'terminal state receipt exists before simulated recovery'
            $result = Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            Assert-CcodEqual 'Complete' ([string]$result.outcome) 'Complete resumes from an existing terminal state receipt'
            Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $evidenceRoot 'acceptance/CodexRemote-fix-2.5.22-official-draft.complete.json') -PathType Leaf) 'recovery writes the missing acceptance artifact'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft accepts persisted Int64 receipt numbers from PowerShell Core' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state
            $preflight = Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters
            $preflightPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '01-Preflight.json'
            $receipt = [IO.File]::ReadAllText($preflightPath) | ConvertFrom-Json
            $receipt.schemaVersion = [int64]$receipt.schemaVersion
            foreach ($defender in @($receipt.facts.defenderReceipts)) {
                $defender.schemaVersion = [int64]$defender.schemaVersion
                $defender.zoneId = [int64]$defender.zoneId
                $defender.detectionCount = [int64]$defender.detectionCount
            }
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                $normalized = &$module {
                    param($Receipt,$Candidate)
                    Assert-CcodOfficialDraftReceiptShape -Receipt $Receipt -ExpectedPhase 'Preflight'
                } $receipt $preflight.candidate
                Assert-CcodEqual 'Preflight' ([string]$normalized.phase) 'Int64 receipt numbers remain readable across PowerShell runtimes'
            } finally {
                if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft optional state probes fail closed on access errors' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows { &$module { Get-CcodOfficialDraftOptionalPathState -Path 'C:\\fixture\\missing.json' -ExpectDirectory $false -GetItem { param($Path) throw [UnauthorizedAccessException]::new('fixture denied') } -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID' } } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
        } finally {
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-CcodTest 'official draft default observations reject wrong-type install residue' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-observation-' + [guid]::NewGuid().ToString('N'))
        $runtime = Join-Path $root 'runtime'
        $pointer = Join-Path $root 'active.json'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $realIntegration = & $module { Get-CcodOfficialDraftIntegrationModule }
        $state = [pscustomobject]@{ Facts = (New-CcodAcceptanceRawFacts -Absent); Probes = [Collections.Generic.List[string]]::new() }
        $fakeIntegration = New-Module -ArgumentList $state,$realIntegration -ScriptBlock {
            param($State,$Real)
            function Get-CcodInstalledLifecycleFacts {
                param([string]$InstallRoot,[string]$ExpectedVersion)
                $observed = $State.Facts.PSObject.Copy()
                & $Real {
                    param($Root,$Facts,$State)
                    $probe = { param($Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
                    $runtimePath = Join-Path $Root 'runtime'
                    $pointerPath = Join-Path $Root 'active.json'
                    $State.Probes.Add($runtimePath)
                    $Facts.runtimeRootPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $runtimePath -GetItem $probe
                    $State.Probes.Add($pointerPath)
                    $Facts.activePointerPresent = $null -ne (Get-CcodInstalledLifecycleOptionalRegularFileState -Path $pointerPath -GetItem $probe)
                } $InstallRoot $observed $State
                return $observed
            }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        try {
            $capture = & $module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                (Get-CcodOfficialDraftDefaultAdapters).CaptureFacts
            } $fakeIntegration $root
            foreach ($kind in @('Runtime','Pointer')) {
                [IO.Directory]::CreateDirectory($runtime) | Out-Null
                [IO.File]::WriteAllText($pointer,'{}',[Text.UTF8Encoding]::new($false))
                $control = & $capture ([pscustomobject]@{ phase = 'Preflight' }) 'Before'
                Assert-CcodTrue ($control.runtimeRootPresent -and $control.activePointerPresent) 'real path probes accept the valid directory/file pair'
                $badPath = if ($kind -ceq 'Runtime') { $runtime } else { $pointer }
                Remove-Item -LiteralPath $badPath -Recurse -Force
                if ($kind -ceq 'Runtime') { [IO.File]::WriteAllText($runtime,'wrong-type') }
                else { [IO.Directory]::CreateDirectory($pointer) | Out-Null }
                $previousProbes = $state.Probes.Count
                Assert-CcodThrows { & $capture ([pscustomobject]@{ phase = 'Preflight' }) 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
                Assert-CcodTrue ($state.Probes.Count -gt $previousProbes) 'the invalid target reaches the production path probe'
                Assert-CcodEqual $badPath $state.Probes[$state.Probes.Count - 1] 'the intended wrong-type path, not an earlier fixture defect, rejects'
                Remove-Item -LiteralPath $runtime -Recurse -Force
                Remove-Item -LiteralPath $pointer -Recurse -Force
            }
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft default observations reject incomplete integration facts' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-incomplete-facts-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $fakeIntegration = New-Module -ScriptBlock {
            function Get-CcodInstalledLifecycleFacts {
                param([string]$InstallRoot,[string]$ExpectedVersion)
                return [pscustomobject][ordered]@{
                    taskState = 'Absent'; supervisor = @(); trayHost = @()
                    deviceKeyPresent = $true; deviceKeySha256 = ('b' * 64)
                }
            }
            function Read-CcodInstalledLifecycleStatusFact { param([string]$StateRoot); return $null }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts,Read-CcodInstalledLifecycleStatusFact
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows {
                &$module {
                    param($Fake,$InstallRoot)
                    $script:CcodOfficialDraftIntegrationModule = $Fake
                    $script:CcodOfficialDraftInstallRoot = $InstallRoot
                    $adapters = Get-CcodOfficialDraftDefaultAdapters
                    & $adapters.CaptureFacts ([pscustomobject]@{ phase = 'Uninstall' }) 'After' | Out-Null
                } $fakeIntegration $root
            } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft optional path probe fails closed on access errors' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows {
                &$module {
                    $probe = { param($Path) throw [UnauthorizedAccessException]::new('fixture access denied') }
                    Get-CcodOfficialDraftOptionalPathState -Path 'C:\fixture\blocked' -ExpectDirectory $true -GetItem $probe -ErrorId 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
                }
            } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft optional missing path rejects a reparse ancestor' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-optional-reparse-' + [guid]::NewGuid().ToString('N'))
        $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-optional-reparse-outside-' + [guid]::NewGuid().ToString('N'))
        $module = $null
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            [IO.Directory]::CreateDirectory($outside) | Out-Null
            $ancestor = Join-Path $root 'ancestor'
            New-Item -ItemType Junction -Path $ancestor -Target $outside | Out-Null
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            Assert-CcodThrows {
                &$module {
                    param($Path)
                    $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
                    Get-CcodOfficialDraftOptionalPathState -Path $Path -ExpectDirectory $false -GetItem $probe -ErrorId 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
                } (Join-Path $ancestor 'missing.txt')
            } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft cleanup validates ancestors before accepting a missing target' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-cleanup-missing-reparse-' + [guid]::NewGuid().ToString('N'))
        $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-cleanup-missing-reparse-outside-' + [guid]::NewGuid().ToString('N'))
        $junction = Join-Path $root 'unsafe'
        $target = Join-Path $junction 'missing.json'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            Assert-CcodThrows {
                &$module { param($Path) Remove-CcodOfficialDraftCompleteArtifacts -Paths @($Path) -ExpectedHashes @{} } $target | Out-Null
            } 'CCOD_ACCEPTANCE_COMPLETE_CLEANUP_FAILED'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $junction) { Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default observations recheck the install root after mutation' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-root-recheck-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $facts = New-CcodAcceptanceRawFacts -Absent
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param([string]$InstallRoot,[string]$ExpectedVersion); return $Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $capture = & $module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                (Get-CcodOfficialDraftDefaultAdapters).CaptureFacts
            } $fakeIntegration $root
            $context = [pscustomobject]@{ phase = 'Preflight' }
            $control = & $capture $context 'After'
            Assert-CcodTrue $control.installRootPresent 'valid directory control succeeds before changing only the root type'
            Remove-Item -LiteralPath $root -Recurse -Force
            [IO.File]::WriteAllText($root,'root residue',[Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { & $capture $context 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if ([IO.File]::Exists($root)) { Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue }
            if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default observations reject pseudo-integer generations' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-generation-type-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $facts = New-CcodAcceptanceRawFacts
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param([string]$InstallRoot,[string]$ExpectedVersion); return $Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $capture = & $module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                (Get-CcodOfficialDraftDefaultAdapters).CaptureFacts
            } $fakeIntegration $root
            $context = [pscustomobject]@{ phase = 'Preflight'; expectedVersion = '2.5.22' }
            foreach ($bad in @([double]2,[bool]$true,'2',([object[]]@(2)))) {
                $facts.activeGeneration = [uint64]2
                $control = & $capture $context 'After'
                Assert-CcodEqual ([uint64]2) $control.activeGeneration 'the complete raw fixture exposes its valid generation'
                $facts.activeGeneration = $bad
                Assert-CcodThrows { & $capture $context 'After' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            }
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default observations accept Int64 process identities' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-pid-type-' + [guid]::NewGuid().ToString('N'))
        $logs = Join-Path $root 'logs'
        [IO.Directory]::CreateDirectory((Join-Path $root 'runtime')) | Out-Null
        [IO.Directory]::CreateDirectory($logs) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), '{}', [Text.UTF8Encoding]::new($false))
        $trayReady = [ordered]@{
            schemaVersion = 1; timestampUtc = '2030-02-03T04:05:03.0000000Z'; component = 'Supervisor'; stage = 'TrayHostReady'
            code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201
            hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2
        }
        [IO.File]::WriteAllText((Join-Path $logs 'supervisor.log'), (($trayReady | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $facts = [pscustomobject][ordered]@{
            installRootPresent = $true; appPresent = $true; runtimeRootPresent = $true; activePointerPresent = $true; activeRuntimeId = 'runtime-2.5.22'; activeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64)
            supervisor = @([pscustomobject]@{ pid = 200; creationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
            trayHost = @([pscustomobject]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
            trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }
            codex = @([pscustomobject]@{ pid = [int64]202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }); codexCount = [int64]1
            trayAuthenticated = $true
            taskState = 'Ready'; statusPhase = 'Active'; statusRuntimeId = 'runtime-2.5.22'
            statusCodex = [pscustomobject]@{ pid = [int64]202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
            transitionStage = 'Idle'; lifecycleReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; phase = 'Completed' }
            aboutVersion = '2.5.22'; deviceKeyPresent = $true; deviceKeySha256 = ('b' * 64)
            shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
            debugEndpoints = @([pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' },[pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' })
            debugPorts = @(9229,9230)
        }
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param([string]$InstallRoot,[string]$ExpectedVersion); return $Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $observed = &$module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $adapters = Get-CcodOfficialDraftDefaultAdapters
                & $adapters.CaptureFacts ([pscustomobject]@{ phase = 'LegacyUpgrade'; expectedVersion = '2.5.22' }) 'After'
            } $fakeIntegration $root
            Assert-CcodTrue ([bool]$observed.trayAuthenticated) 'Int64 process identities preserve authenticated readiness'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default legacy observations reject a missing installed baseline' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-legacy-baseline-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # The integration helper's protected event and CIM behavior have separate native tests.
    $state = [pscustomobject]@{ Facts = (New-CcodAcceptanceRawFacts); Calls = 0; ReadyCalls = 0; Ready = $true }
    $state.Facts.aboutVersion = '2.5.21'
    $state.Facts.activeRuntimeId='2.5.21-e3b0c44298fc1c14'
    $state.Facts.statusRuntimeId=$state.Facts.activeRuntimeId
    $state.Facts.lifecycleReceipt.runtimeId=$state.Facts.activeRuntimeId
    $fakeIntegration = New-Module -ArgumentList $state -ScriptBlock {
        param($State)
        function Get-CcodInstalledLifecycleFacts { param($InstallRoot,$ExpectedVersion) $State.Calls++; return $State.Facts }
        function Get-CcodInstalledLifecycleLegacyTrayReadyProof {
            param($InstallRoot,$RuntimeId,$Supervisor,$TrayHost)
            $State.ReadyCalls++
            if($RuntimeId-cne$State.Facts.activeRuntimeId-or@($Supervisor).Count-ne1-or$Supervisor[0].pid-ne200-or@($TrayHost).Count-ne1-or$TrayHost[0].pid-ne201){throw 'legacy helper arguments'}
            return $State.Ready
        }
        Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts,Get-CcodInstalledLifecycleLegacyTrayReadyProof
    }
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    try {
        $capture = &$module {
            param($Fake,$InstallRoot)
            $script:CcodOfficialDraftIntegrationModule = $Fake
            $script:CcodOfficialDraftInstallRoot = $InstallRoot
            (Get-CcodOfficialDraftDefaultAdapters).CaptureFacts
        } $fakeIntegration $root
        $context = [pscustomobject][ordered]@{ phase='LegacyUpgrade'; expectedVersion='2.5.22'; previousSetup=[pscustomobject]@{version='2.5.21'} }
        $control = & $capture $context 'Before'
        Assert-CcodTrue $control.protectionReady 'legacy observation uses protected event proof without a newer log'
        Assert-CcodEqual 1 $state.ReadyCalls 'default capture invokes the legacy helper once'
        $state.Ready=$false
        $notReady=&$capture $context 'Before'
        Assert-CcodTrue (-not$notReady.protectionReady-and-not$notReady.trayAuthenticated) 'negative protected-event proof cannot become readiness'
        $state.Ready=$true
        $previousCalls = $state.Calls
        $state.Facts = New-CcodAcceptanceRawFacts -Absent
        Assert-CcodThrows { & $capture $context 'Before' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        Assert-CcodEqual ($previousCalls + 1) $state.Calls 'the absent installed observation reaches the same adapter boundary'
    } finally {
        if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest 'official draft default uninstall observations require two debug ports' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-uninstall-ports-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $facts = New-CcodAcceptanceRawFacts
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param([string]$InstallRoot,[string]$ExpectedVersion); return $Facts }
            function Read-CcodInstalledLifecycleStatusFact { param($StateRoot) throw 'status must not be reread after the fact snapshot' }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts,Read-CcodInstalledLifecycleStatusFact
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $capture = & $module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule=$Fake
                $script:CcodOfficialDraftInstallRoot=$InstallRoot
                (Get-CcodOfficialDraftDefaultAdapters).CaptureFacts
            } $fakeIntegration $root
            $context = [pscustomobject]@{ phase='Uninstall' }
            foreach ($bad in @(@(),@(9229),@(9229,9229),@([double]9229.25,9230),'9229')) {
                $facts.debugPorts = @(9229,9230)
                $control = & $capture $context 'Before'
                Assert-CcodEqual '9229,9230' ($control.debugPorts -join ',') 'two captured ports are accepted before a single port-shape mutation'
                $facts.debugPorts = $bad
                Assert-CcodThrows { & $capture $context 'Before' | Out-Null } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            }
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft default observations include the current boot identity' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-default-boot-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'runtime')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'logs')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), '{}', [Text.UTF8Encoding]::new($false))
        $trayReady = [ordered]@{ schemaVersion = 1; timestampUtc = '2030-02-03T04:05:03.0000000Z'; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = [UInt64]2 }
        [IO.File]::WriteAllText((Join-Path $root 'logs\supervisor.log'), (($trayReady | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $facts = New-CcodAcceptanceFacts -BootId 'fixture-ignored'
        $facts | Add-Member -NotePropertyName appPresent -NotePropertyValue $true
        $facts.aboutVersion = '2.5.22'
        $fakeIntegration = New-Module -ArgumentList $facts -ScriptBlock {
            param($Facts)
            function Get-CcodInstalledLifecycleFacts { param([string]$InstallRoot,[string]$ExpectedVersion); return $Facts }
            Export-ModuleMember -Function Get-CcodInstalledLifecycleFacts
        }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $observed = &$module {
                param($Fake,$InstallRoot)
                $script:CcodOfficialDraftIntegrationModule = $Fake
                $script:CcodOfficialDraftInstallRoot = $InstallRoot
                $adapters = Get-CcodOfficialDraftDefaultAdapters
                & $adapters.CaptureFacts ([pscustomobject]@{ phase = 'PostReboot'; expectedVersion = '2.5.22' }) 'After'
            } $fakeIntegration $root
            Assert-CcodTrue ($observed.bootId -is [string] -and $observed.bootId.Length -gt 0) 'default observations include a sanitized boot identity'
            Assert-CcodTrue ($observed.trayAuthenticated -and $observed.protectionReady) 'default observations require the authenticated tray proof and matching runtime status'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if ($null -ne $fakeIntegration) { Remove-Module -Name $fakeIntegration.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft post-reboot rejects an observed active generation that differs from the terminal receipt' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            $state.BootId = 'boot-2'
            $state.Facts = New-CcodAcceptanceFacts -BootId 'boot-2'
            $state.Facts.activeRuntimeId = 'runtime-attacker'
            $state.Facts.activeGeneration = [UInt64]99
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase PostReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            } 'CCOD_ACCEPTANCE_POST_REBOOT_OBSERVATION_INVALID'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft replay rejects a tampered PreReboot continuity identity' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $path = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '05-PreReboot.json'
            $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $receipt.facts.activeRuntimeId = 'runtime-tampered'
            [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try { Assert-CcodThrows { &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } (Join-Path $evidenceRoot 'official-draft-acceptance') } 'CCOD_ACCEPTANCE_RECEIPT_INVALID' } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft replay revalidates the fixed v2.5.21 setup and manifest bytes' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $path = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '02-LegacyUpgrade.json'
            $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $receipt.facts.previousSetup.assetSha256 = ('e' * 64)
            [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                Assert-CcodThrows { &$module { param($Directory,$Previous) Read-CcodOfficialDraftState -StateDirectory $Directory -PreviousAssetDirectory $Previous } (Join-Path $evidenceRoot 'official-draft-acceptance') $previousRoot } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft replay rejects a detached PreReboot runtime manifest hash' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $path = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '05-PreReboot.json'
            $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $receipt.facts.observation.runtimeManifestSha256 = ('e' * 64)
            [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try { Assert-CcodThrows { &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } (Join-Path $evidenceRoot 'official-draft-acceptance') } 'CCOD_ACCEPTANCE_RECEIPT_INVALID' } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft replay rejects a PostReboot TrayHost identity detached from its observation' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $path = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '06-PostReboot.json'
            $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $receipt.facts.trayHostIdentity.pid = 999
            [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try { Assert-CcodThrows { &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } (Join-Path $evidenceRoot 'official-draft-acceptance') } 'CCOD_ACCEPTANCE_RECEIPT_INVALID' } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft replay rejects a broken device-key chain across uninstall' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $path = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '03-Uninstall.json'
            $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $receipt.facts.deviceKeySha256Before = ('c' * 64)
            $receipt.facts.deviceKeySha256After = ('c' * 64)
            [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                Assert-CcodThrows { &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } (Join-Path $evidenceRoot 'official-draft-acceptance') } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft state reader rejects a reparse-point state root' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-state-reparse-' + [guid]::NewGuid().ToString('N'))
        $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-state-reparse-outside-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        try {
            New-Item -ItemType Junction -Path $root -Target $outside | Out-Null
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try { Assert-CcodThrows { &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } $root } 'CCOD_ACCEPTANCE_RECEIPT_INVALID' } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft state reader recovers closed orphan create-only temporaries' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-state-orphan-temp-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $acceptanceTemp = Join-Path $root ('.acceptance-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $manualTemp = Join-Path $root ('.manual-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($acceptanceTemp, 'orphan-acceptance', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manualTemp, 'orphan-manual', [Text.UTF8Encoding]::new($false))
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $records = &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } $root
            Assert-CcodTrue ($records.ContainsKey('ManualEvidence')) 'state reader continues after orphan temporary recovery'
            Assert-CcodTrue (-not (Test-Path -LiteralPath $acceptanceTemp) -and -not (Test-Path -LiteralPath $manualTemp)) 'state reader removes only recognized closed orphan temporaries'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft JSONL proofs reject a reparse parent outside the evidence root' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-jsonl-reparse-' + [guid]::NewGuid().ToString('N'))
        $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-jsonl-reparse-outside-' + [guid]::NewGuid().ToString('N'))
        $junction = Join-Path $root 'logs'
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'proof.jsonl'), '{"kind":"fixture"}', [Text.UTF8Encoding]::new($false))
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                Assert-CcodThrows {
                    &$module { param($Path) Get-CcodOfficialDraftJsonLines -Path $Path } (Join-Path $junction 'proof.jsonl')
                } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
            } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            try { if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction, $false) } } catch { }
            try { if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
            try { if ([IO.Directory]::Exists($outside)) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }

    Invoke-CcodTest 'official draft terminal receipts reject floating and boolean generations' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            foreach ($bad in @([double]2,[bool]$true)) {
                $receipt = [pscustomobject][ordered]@{ kind='RestartAndRepair'; origin='Installer'; runtimeId='runtime-2.5.22'; runtimeGeneration=$bad; phase='Completed' }
                Assert-CcodThrows { &$module { param($Value) ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt $Value } $receipt } 'CCOD_ACCEPTANCE_FRESH_INSTALL_OBSERVATION_INVALID'
            }
        } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
    }

    Invoke-CcodTest 'official draft manual records reject lowercase phase variants' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $record = [pscustomobject][ordered]@{
            schemaVersion = 1; kind = 'manual-evidence'; phase = 'TrayEvidence'; operation = 'About'
            terminalState = 'AboutVisible'; result = 'CCOD_TRAYABOUT_COMPLETED'
            proof = [pscustomobject][ordered]@{ timestampUtc = [DateTime]::UtcNow.ToString('o'); command = 'ShowAbout'; revision = 7; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }
            reviewState = 'Reviewed'
            version = '2.5.22'; gitCommit = ('c' * 40); candidateManifestSha256 = ('d' * 64)
            screenshotSha256 = ('1' * 64); redactedLogSha256 = ('2' * 64)
        }
        try {
            $control = & $module { param($Value) Assert-CcodOfficialDraftManualRecordShape -Record $Value } $record
            Assert-CcodEqual 'TrayEvidence' $control.phase 'complete proof with canonical phase succeeds before changing only case'
            $record.phase = 'trayevidence'
            Assert-CcodThrows {
                &$module { param($Value) Assert-CcodOfficialDraftManualRecordShape -Record $Value } $record
            } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
        } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
    }

    Invoke-CcodTest 'official draft removes PreReboot receipt when the authorized reboot fails' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $adapters.Reboot = { $State.RebootCalls++; return $false }.GetNewClosure()
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            } 'CCOD_ACCEPTANCE_REBOOT_FAILED'
            Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '05-PreReboot.json') -PathType Leaf)) 'failed reboot does not strand the PreReboot receipt'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft receipt writer never deletes a colliding temporary file' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-receipt-collision-' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $root 'receipt.json'
        $collision = [hashtable]@{ Path = $null }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            $beforeOpen = {
                param($Path)
                $collision.Path = $Path
                [IO.File]::WriteAllText($Path, 'foreign temporary content', [Text.UTF8Encoding]::new($false))
            }.GetNewClosure()
            Assert-CcodThrows {
                &$module { param($Path,$Callback) Write-CcodOfficialDraftJsonCreateOnly -Path $Path -Record ([ordered]@{ value = 'fixture' }) -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_WRITE_FAILED' -BeforeTemporaryOpen $Callback | Out-Null } $target $beforeOpen
            } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_CLEANUP_FAILED'
            Assert-CcodTrue ($null -ne $collision.Path -and [IO.File]::Exists($collision.Path)) 'foreign temporary file remains untouched after collision'
            Assert-CcodEqual 'foreign temporary content' ([IO.File]::ReadAllText($collision.Path)) 'foreign temporary content is preserved'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft Complete reports cleanup failure instead of hiding a terminal residue' {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('ccod-complete-cleanup-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, 'fixture', [Text.UTF8Encoding]::new($false))
        $expectedHash = Get-CcodTestFileSha256 -Path $path
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            & $module { param($Target,$Hash) Remove-CcodOfficialDraftCompleteArtifacts -Paths @($Target) -ExpectedHashes @{ ([IO.Path]::GetFullPath($Target)) = $Hash } | Out-Null } $path $expectedHash
            Assert-CcodTrue (-not (Test-Path -LiteralPath $path)) 'valid owned-file cleanup succeeds before the failing callback'
            foreach ($mode in @('Throw','LeaveResidue')) {
                [IO.File]::WriteAllText($path,'fixture',[Text.UTF8Encoding]::new($false))
                $state = [pscustomobject]@{ Calls = 0; Mode = $mode }
                $remove = { param($Path) $state.Calls++; if ($state.Mode -ceq 'Throw') { throw 'fixture cleanup failure' } }.GetNewClosure()
                Assert-CcodThrows {
                    &$module {
                        param($Target,$Hash,$Remove)
                        Remove-CcodOfficialDraftCompleteArtifacts -Paths @($Target) -ExpectedHashes @{ ([IO.Path]::GetFullPath($Target)) = $Hash } -RemovePath $Remove
                    } $path $expectedHash $remove
                } 'CCOD_ACCEPTANCE_COMPLETE_CLEANUP_FAILED'
                Assert-CcodEqual 1 $state.Calls 'the valid hash reaches the actual deletion callback'
                Assert-CcodTrue (Test-Path -LiteralPath $path -PathType Leaf) 'failed deletion leaves an explicitly reported residue'
                Assert-CcodEqual $expectedHash (Get-CcodTestFileSha256 -Path $path) 'failed deletion does not change the owned bytes'
            }
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft receipt chain rejects a detached Complete candidate' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        [IO.Directory]::CreateDirectory($manualRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Invoke-CcodAcceptanceManualRecords -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -Paths $paths
            Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            $stateDirectory = Join-Path $evidenceRoot 'official-draft-acceptance'
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                $records = &$module { param($Directory) Read-CcodOfficialDraftState -StateDirectory $Directory } $stateDirectory
                $completeRemote = @($records.Complete.facts.manualEvidence | Where-Object { $_.operation -ceq 'SecondDeviceControl' })[0]
                $fileRemote = $records.ManualEvidence['SecondDeviceControl']
                $completeRemote.proof.runtimeId = 'runtime-other'
                $fileRemote.proof.runtimeId = 'runtime-other'
                Assert-CcodThrows {
                    &$module { param($Value,$Directory) Assert-CcodOfficialDraftAutomatedReceiptChain -Records $Value -StateDirectory $Directory } $records $stateDirectory
                } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
                $completeRemote.proof.runtimeId = 'runtime-2.5.22'
                $fileRemote.proof.runtimeId = 'runtime-2.5.22'
                $records.Complete.draft.id = 'different-draft'
                Assert-CcodThrows {
                    &$module { param($Value,$Directory) Assert-CcodOfficialDraftAutomatedReceiptChain -Records $Value -StateDirectory $Directory } $records $stateDirectory
                } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
                $records.Complete.draft.id = '123'
                $detached = [pscustomobject][ordered]@{
                    version = [string]$records.Complete.candidate.version
                    gitCommit = ('d' * 40)
                    assetHashes = @($records.Complete.candidate.assetHashes)
                    manifestHashes = [pscustomobject][ordered]@{ portable = [string]$records.Complete.candidate.manifestHashes.portable; setup = [string]$records.Complete.candidate.manifestHashes.setup }
                }
                $records.Complete.candidate = $detached
                Assert-CcodThrows {
                    &$module { param($Value,$Directory) Assert-CcodOfficialDraftAutomatedReceiptChain -Records $Value -StateDirectory $Directory } $records $stateDirectory
                } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft fresh install rejects a runtime binding detached from the candidate' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $adapters.RunPhase = { param($Context) [pscustomobject][ordered]@{ completed = $true; outcome = 'Completed'; installerSha256 = [string](@($Fixture.Contract.Assets | Where-Object { $_.name -like '*-setup.exe' })[0].sha256); runtimeManifestSha256 = ('1' * 64) } }.GetNewClosure()
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            } 'CCOD_ACCEPTANCE_FRESH_INSTALL_OBSERVATION_INVALID'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'official draft manual evidence rejects files changed after proof capture' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-manual-hash-stability-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $screenshot = Join-Path $root 'screenshot.png'
        $log = Join-Path $root 'redacted.log'
        [IO.File]::WriteAllText($screenshot, 'screenshot-before', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($log, 'log-before', [Text.UTF8Encoding]::new($false))
        $screenshotHash = Get-CcodTestFileSha256 -Path $screenshot
        $logHash = Get-CcodTestFileSha256 -Path $log
        [IO.File]::WriteAllText($log, 'log-after', [Text.UTF8Encoding]::new($false))
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows {
                &$module {
                    param($Screenshot,$Log,$ExpectedScreenshot,$ExpectedLog)
                    Assert-CcodOfficialDraftEvidenceHashesStable -ScreenshotPath $Screenshot -RedactedLogPath $Log -ExpectedScreenshotSha256 $ExpectedScreenshot -ExpectedRedactedLogSha256 $ExpectedLog
                } $screenshot $log $screenshotHash $logHash
            } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft manual artifacts reject files larger than two MiB' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-manual-size-bound-' + [guid]::NewGuid().ToString('N'))
        $artifactRoot = Join-Path $root 'artifacts'
        $screenshot = Join-Path $root 'screenshot.png'
        $log = Join-Path $root 'redacted.log'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllBytes($screenshot, [byte[]]::new((2MB) + 1))
        [IO.File]::WriteAllText($log, 'bounded-log', [Text.UTF8Encoding]::new($false))
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows {
                &$module {
                    param($Artifact,$Shot,$Log,$ShotHash,$LogHash)
                    Write-CcodOfficialDraftManualArtifacts -ArtifactDirectory $Artifact -Operation 'About' -ScreenshotPath $Shot -RedactedLogPath $Log -ExpectedScreenshotSha256 $ShotHash -ExpectedRedactedLogSha256 $LogHash | Out-Null
                } $artifactRoot $screenshot $log (Get-CcodTestFileSha256 -Path $screenshot) (Get-CcodTestFileSha256 -Path $log)
            } 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft regular file validation rejects noncanonical paths' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-noncanonical-file-' + [guid]::NewGuid().ToString('N'))
        $nested = Join-Path $root 'nested'
        $file = Join-Path $root 'evidence.log'
        [IO.Directory]::CreateDirectory($nested) | Out-Null
        [IO.File]::WriteAllText($file, 'fixture', [Text.UTF8Encoding]::new($false))
        $noncanonical = Join-Path $nested '..\evidence.log'
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            Assert-CcodThrows {
                &$module { param($Path) Get-CcodOfficialDraftFileSha256 -Path $Path } $noncanonical
            } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Invoke-CcodTest 'official draft atomic receipt writer removes a destination that fails readback' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-receipt-readback-' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $root 'receipt.json'
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            [IO.Directory]::CreateDirectory($root) | Out-Null
            $state = [pscustomobject]@{ Calls = 0; PublishedPresent = $false }
            $readback = { param($Path) $state.Calls++; $state.PublishedPresent = ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop) -is [IO.FileInfo]); return $false }.GetNewClosure()
            $failure = &$module {
                param($Path,$Callback)
                $hash = $null
                try { Write-CcodOfficialDraftJsonCreateOnly -Path $Path -Record ([ordered]@{ value = 'fixture' }) -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_WRITE_FAILED' -Readback $Callback -PublishedHash ([ref]$hash) | Out-Null }
                catch { return [pscustomobject][ordered]@{ ErrorId = $_.FullyQualifiedErrorId; PublishedHash = $hash } }
            } $target $readback
            Assert-CcodEqual 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_WRITE_FAILED' $failure.ErrorId 'receipt writer preserves the original write failure after readback cleanup'
            Assert-CcodTrue ($failure.PublishedHash -is [string] -and $failure.PublishedHash -cmatch '^[0-9a-f]{64}\z') 'receipt writer registers the published hash before readback'
            Assert-CcodEqual 1 $state.Calls 'the actual readback callback reported failure'
            Assert-CcodTrue $state.PublishedPresent 'readback left the published file for production rollback'
            Assert-CcodTrue (-not [IO.File]::Exists($target)) 'receipt writer cleans a published destination after failed readback'
            $successTarget = Join-Path $root 'success.json'
            $publishedHash = &$module { param($Path) $hash = $null; Write-CcodOfficialDraftJsonCreateOnly -Path $Path -Record ([ordered]@{ value = 'fixture' }) -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_WRITE_FAILED' -PublishedHash ([ref]$hash) | Out-Null; return $hash } $successTarget
            Assert-CcodTrue ($publishedHash -match '^[0-9a-f]{64}\z') 'receipt writer returns the intended hash before any caller cleanup'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Invoke-CcodTest 'official draft receipt writer removes a destination that fails readback' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-receipt-readback-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $candidate = [pscustomobject][ordered]@{ version = $fixture.Version; gitCommit = $fixture.GitCommit; assetHashes = @($fixture.Contract.Assets); manifestHashes = [pscustomobject][ordered]@{ portable = $fixture.Contract.PortableManifestSha256; setup = $fixture.Contract.SetupManifestSha256 } }
        $draft = [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = '123' }
        $setupReceipt = New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType Setup
        $portableReceipt = New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType PortableZip
        $facts = [pscustomobject][ordered]@{ defenderReceipts = @($setupReceipt,$portableReceipt) }
        try {
            $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
            try {
                $state = [pscustomobject]@{ Calls = 0; PublishedPresent = $false }
                $readback = { param($Path) $state.Calls++; $state.PublishedPresent = ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop) -is [IO.FileInfo]); return $false }.GetNewClosure()
                Assert-CcodThrows {
                    &$module { param($Root,$Candidate,$Draft,$Facts,$Callback) Write-CcodOfficialDraftReceipt -StateDirectory $Root -Phase Preflight -Candidate $Candidate -Draft $Draft -Facts $Facts -ReadbackVerifier $Callback | Out-Null } $root $candidate $draft $facts $readback
                } 'CCOD_ACCEPTANCE_RECEIPT_WRITE_FAILED'
                Assert-CcodEqual 1 $state.Calls 'the phase receipt reaches actual readback'
                Assert-CcodTrue $state.PublishedPresent 'the callback does not pre-delete the published phase receipt'
                Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $root '01-Preflight.json'))) 'receipt writer cleans a published destination after failed readback'
            } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft receipt writer registers its hash before readback failure' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-receipt-published-hash-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $candidate = [pscustomobject][ordered]@{ version = $fixture.Version; gitCommit = $fixture.GitCommit; assetHashes = @($fixture.Contract.Assets); manifestHashes = [pscustomobject][ordered]@{ portable = $fixture.Contract.PortableManifestSha256; setup = $fixture.Contract.SetupManifestSha256 } }
        $draft = [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = '123' }
        $facts = [pscustomobject][ordered]@{ defenderReceipts = @((New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType Setup),(New-CcodAcceptanceDefenderReceipt -Fixture $fixture -AssetType PortableZip)) }
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        try {
            $hash = $null
            $failure = &$module {
                param($Root,$Candidate,$Draft,$Facts,$HashRef)
                $readback = { param($Path) throw 'forced readback failure' }
                try { Write-CcodOfficialDraftReceipt -StateDirectory $Root -Phase Preflight -Candidate $Candidate -Draft $Draft -Facts $Facts -ReadbackVerifier $readback -PublishedHash $HashRef | Out-Null }
                catch { [pscustomobject][ordered]@{ ErrorId = $_.FullyQualifiedErrorId; Hash = $HashRef.Value } }
            } $root $candidate $draft $facts ([ref]$hash)
            Assert-CcodEqual 'CCOD_ACCEPTANCE_RECEIPT_WRITE_FAILED' $failure.ErrorId 'receipt writer retains write error identity after readback failure'
            Assert-CcodTrue ($failure.Hash -is [string] -and $failure.Hash -cmatch '^[0-9a-f]{64}\z') 'receipt writer exposes the published hash before readback'
            Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $root '01-Preflight.json'))) 'throwing readback still rolls back the destination'
        } finally {
            if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-CcodTest 'official draft Complete rereads the automated chain before publishing terminal acceptance' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        $manualRoot = Join-Path $fixture.Root 'manual-input'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        [IO.Directory]::CreateDirectory($manualRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptanceThroughReady -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -State $state
            $paths = New-CcodAcceptanceManualInputFiles -Root $manualRoot
            Invoke-CcodAcceptanceManualRecords -Fixture $fixture -PreviousRoot $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -Paths $paths
            $adapters.GetUtcNow = {
                $postPath = Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '06-PostReboot.json'
                $post = [IO.File]::ReadAllText($postPath) | ConvertFrom-Json
                $post.facts.installRootPresent = $false
                [IO.File]::WriteAllText($postPath, ($post | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
                return [datetime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()
            }.GetNewClosure()
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase Complete -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path (Join-Path $evidenceRoot 'official-draft-acceptance') '08-Complete.json') -PathType Leaf)) 'tampered automated chain does not leave a Complete receipt'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }

    Invoke-CcodTest 'persisted PostReboot facts require an installed root and active pointer' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $facts = [pscustomobject][ordered]@{
            observation = [pscustomobject][ordered]@{
                version = '2.5.22'; bootId = 'boot-after'; installRootPresent = $true; installReady = $true; appRootPresent = $true; runtimeRootPresent = $true; activePointerPresent = $true
                activeRuntimeId = 'runtime-2.5.22'; activeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64)
                supervisor = @([pscustomobject][ordered]@{ pid = 200; creationTimeUtc = '2030-02-03T04:05:00.0000000Z' })
                trayHost = @([pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' })
                codex = @([pscustomobject][ordered]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }); codexCount = 1
                trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }; trayAuthenticated = $true
                taskState = 'Ready'; statusPhase = 'Active'; statusRuntimeId = 'runtime-2.5.22'; statusCodex = [pscustomobject][ordered]@{ pid = 202; creationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
                transitionStage = 'Idle'; lifecycleReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; phase = 'Completed' }; aboutVersion = '2.5.22'
                deviceKeyPresent = $true; deviceKeySha256 = ('b' * 64); shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
                debugPorts = @(9229,9230); debugEndpoints = @(
                    [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
                    [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = 202; owningProcessCreationTimeUtc = '2030-02-03T04:05:02.0000000Z' }
                ); protectionReady = $true
            }
            installRootPresent = $true; activePointerPresent = $true
            bootIdBefore = 'boot-before'; bootIdAfter = 'boot-after'; bootChanged = $true; receiptContinuity = $true
            activeRuntimeId = 'runtime-2.5.22'; activeGeneration = [UInt64]2; runtimeManifestSha256 = ('d' * 64)
            transitionStage = 'Idle'; protectionRecovered = $true; protectionReady = $true; taskState = 'Ready'
            supervisorCount = 1; trayHostCount = 1; codexCount = 1
            trayHostIdentity = [pscustomobject][ordered]@{ pid = 201; creationTimeUtc = '2030-02-03T04:05:01.0000000Z' }
            trayAuthenticated = $true
            terminalReceipt = [pscustomobject][ordered]@{ kind = 'RestartAndRepair'; origin = 'Installer'; runtimeId = 'runtime-2.5.22'; runtimeGeneration = [UInt64]2; phase = 'Completed' }
            deviceKeySha256 = ('b' * 64); keyHashPreserved = $true; operationOutcome = 'Completed'
        }
        try {
            $valid = &$module { param($Value) Assert-CcodOfficialDraftPersistedPhaseFacts -Phase 'PostReboot' -Facts $Value } $facts
            Assert-CcodTrue ($null -ne $valid) 'persisted PostReboot facts accept both required presence flags'
            foreach ($name in @('installRootPresent','activePointerPresent')) {
                $tampered = [pscustomobject][ordered]@{}
                foreach ($property in $facts.PSObject.Properties) { $tampered | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
                $tampered.$name = $false
                Assert-CcodThrows { &$module { param($Value) Assert-CcodOfficialDraftPersistedPhaseFacts -Phase 'PostReboot' -Facts $Value } $tampered | Out-Null } 'CCOD_ACCEPTANCE_RECEIPT_INVALID'
            }
        } finally { if ($null -ne $module) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue } }
    }

    Invoke-CcodTest 'official draft preserves an inner terminal receipt error identity' {
        $source = [IO.File]::ReadAllText($modulePath, [Text.UTF8Encoding]::new($false))
        $start = $source.IndexOf('function ConvertTo-CcodOfficialDraftTerminalReceipt')
        $end = $source.IndexOf('function Assert-CcodOfficialDraftFreshFacts', $start)
        Assert-CcodTrue ($start -ge 0 -and $end -gt $start) 'terminal receipt converter source is present'
        $block = $source.Substring($start, $end - $start)
        Assert-CcodTrue ($block.Contains("if (`$_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }")) 'terminal receipt conversion preserves an existing acceptance error id'
    }

    Invoke-CcodTest 'official draft hashes manual artifacts with their own error context' {
        $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $missing = Join-Path ([IO.Path]::GetTempPath()) ('ccod-missing-manual-' + [guid]::NewGuid().ToString('N') + '.bin')
        try {
            $observed = & $module {
                param($Path)
                try { Get-CcodOfficialDraftFileSha256 -Path $Path -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'manual artifact unavailable' | Out-Null; 'NO_ERROR' } catch { [string]$_.FullyQualifiedErrorId }
            } $missing
            Assert-CcodEqual 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' $observed 'manual artifact hash failures retain the manual evidence error context'
        } finally { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
    }

    Invoke-CcodTest 'official draft pre-reboot binds the captured boot identity' {
        $fixture = New-CcodAcceptanceCandidateFixture
        $previousRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-acceptance-previous-' + [guid]::NewGuid().ToString('N'))
        $evidenceRoot = Join-Path $fixture.Root 'evidence'
        [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $state = [pscustomobject]@{ DefenderCalls = [Collections.Generic.List[string]]::new(); RunCalls = [Collections.Generic.List[string]]::new(); CaptureCalls = [Collections.Generic.List[string]]::new(); BootCalls = 0; RebootCalls = 0; PreviousCalls = 0; BootId = 'boot-1'; KeyHash = ('b' * 64); Facts = New-CcodAcceptanceFacts }
        try {
            $adapters = New-CcodAcceptancePhaseAdapters -Fixture $fixture -State $state -ReturnAbsentAfterUninstall
            Invoke-CcodAcceptancePrivate -Phase Preflight -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters | Out-Null
            Invoke-CcodAcceptancePrivate -Phase LegacyUpgrade -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase Uninstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            Invoke-CcodAcceptancePrivate -Phase FreshInstall -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart | Out-Null
            $adapters.GetBootIdentity = { return 'boot-external' }
            Assert-CcodThrows {
                Invoke-CcodAcceptancePrivate -Phase PreReboot -AssetDirectory $fixture.Root -PreviousAssetDirectory $previousRoot -EvidenceRoot $evidenceRoot -Adapters $adapters -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot | Out-Null
            } 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
            Assert-CcodEqual 0 $state.RebootCalls 'boot identity mismatch cannot reach the reboot adapter'
        } finally {
            if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
            if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        }
    }
} catch {
    Write-Error $_
    exit 1
}

Write-Host 'Official-draft acceptance harness self-tests passed.'
