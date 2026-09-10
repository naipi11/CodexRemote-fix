[CmdletBinding()]
param([ValidateSet('Draft','Wrapper','Contract','Acceptance','Lease')][string]$Case)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:executed = 0
$script:skipped = 0
function Invoke-CcodImportTest {
    param([string]$Area,[string]$Name,[scriptblock]$Action)
    if ($Case -and $Case -cne $Area) { $script:skipped++; return }
    $script:executed++
    Invoke-CcodTest $Name $Action
}

function New-CcodImportFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-import-' + [guid]::NewGuid().ToString('N'))
    $tools = Join-Path $root 'repo\tools'
    [IO.Directory]::CreateDirectory($tools) | Out-Null
    [pscustomobject]@{ Root = $root; Tools = $tools; Marker = (Join-Path $root 'substitution-executed.txt') }
}

function New-CcodImportDraftModule {
    param($Fixture)
    $source = Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1'
    $module = New-Module -Name ('CcodImportDraft-' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create([IO.File]::ReadAllText($source)))
    & $module { param($Tools) $script:CcodGitHubDraftModuleRoot = $Tools } $Fixture.Tools
    return $module
}

Invoke-CcodImportTest 'Draft' 'draft first dependency cannot be replaced after path validation before real import' {
    $fixture = New-CcodImportFixture
    $module = $null
    try {
        $path = Join-Path $fixture.Tools 'ReleaseAssetContract.psm1'
        [IO.File]::WriteAllText($path, 'function Get-CcodI8Origin { $PSScriptRoot }; Export-ModuleMember -Function Get-CcodI8Origin', [Text.UTF8Encoding]::new($false))
        $module = New-CcodImportDraftModule $fixture
        $observed = & $module {
            param($Marker)
            $script:I8Marker = $Marker
            $script:I8Reached = $false
            $script:I8Blocked = $false
            $script:I8OriginalValidator = ${function:Assert-CcodGitHubDraftTrustedModulePath}
            function Assert-CcodGitHubDraftTrustedModulePath {
                param([string]$Path,[bool]$Directory)
                $result = & $script:I8OriginalValidator -Path $Path -Directory $Directory
                if (-not $Directory) {
                    $script:I8Reached = $true
                    $replacement = '[IO.File]::WriteAllText(''' + $script:I8Marker.Replace("'", "''") + ''',''substituted'')'
                    try { [IO.File]::WriteAllText($Path, $replacement) }
                    catch [IO.IOException] { $script:I8Blocked = $true }
                }
                return $result
            }
            Import-CcodDraftReleaseAssetContract
            [pscustomobject]@{
                Reached = $script:I8Reached
                Blocked = $script:I8Blocked
                Imported = $script:CcodDraftReleaseAssetContractModule
            }
        } $fixture.Marker
        Assert-CcodTrue $observed.Reached 'mutation seam follows the real successful path validator'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $fixture.Marker)) 'replacement initializer never executes through the real loader'
        Assert-CcodTrue $observed.Blocked 'module overwrite is denied while import authority is held'
        Assert-CcodTrue ($observed.Imported -is [Management.Automation.PSModuleInfo]) 'real import returns a PSModuleInfo'
        Assert-CcodEqual $fixture.Tools (& $observed.Imported { Get-CcodI8Origin }) 'original module retains PSScriptRoot and private callback semantics'
        Remove-Module $observed.Imported -Force
        [IO.File]::WriteAllText($path, '# writable after import')
    } finally {
        if ($null -ne $module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
        Get-Module | Where-Object { $_.Path -and $_.Path.StartsWith($fixture.Root, [StringComparison]::OrdinalIgnoreCase) } | Remove-Module -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

function Set-CcodImportMutationTrap {
    param($Module,[string]$Target)
    & $Module {
        param($Target)
        $script:I8Target = $Target
        $script:I8LoaderReached = $false
        $script:I8Denied = [Collections.Generic.List[string]]::new()
        function script:Import-Module {
            [CmdletBinding()]
            param([Parameter(Position=0)]$Name,[switch]$Force,[switch]$PassThru,[switch]$DisableNameChecking)
            if ([string]::Equals([string]$Name, $script:I8Target, [StringComparison]::OrdinalIgnoreCase)) {
                $script:I8LoaderReached = $true
                foreach ($operation in @('Write','Delete','Parent','Ancestor')) {
                    try {
                        if ($operation -in @('Write','Delete')) {
                            $bytes = [IO.File]::ReadAllBytes($Name)
                            if ($operation -ceq 'Write') { [IO.File]::WriteAllBytes($Name, $bytes) }
                            else { [IO.File]::Delete($Name); [IO.File]::WriteAllBytes($Name, $bytes) }
                        } else {
                            $directory = [IO.Path]::GetDirectoryName($Name)
                            if ($operation -ceq 'Ancestor') { $directory = [IO.Path]::GetDirectoryName($directory) }
                            [IO.Directory]::Move($directory, $directory + '-moved')
                            [IO.Directory]::Move($directory + '-moved', $directory)
                        }
                    } catch [IO.IOException] { $script:I8Denied.Add($operation) }
                }
            }
            $arguments = @{}
            foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
            $arguments.PassThru = $true
            $script:I8Imported = Microsoft.PowerShell.Core\Import-Module @arguments
            if ($PassThru) { return $script:I8Imported }
        }
    } $Target
}

function Assert-CcodImportMutationTrap {
    param($Module)
    $state = & $Module { [pscustomobject]@{ Reached = $script:I8LoaderReached; Denied = @($script:I8Denied.ToArray()) } }
    Assert-CcodTrue $state.Reached 'the real import boundary was reached'
    Assert-CcodEqual 'Write,Delete,Parent,Ancestor' ($state.Denied -join ',') 'leaf and complete ancestor chain are held through the real loader call'
}

function Get-CcodImportSlice {
    param([string]$Source,[string]$Start,[string]$End)
    $text = [IO.File]::ReadAllText($Source)
    $begin = $text.IndexOf($Start, [StringComparison]::Ordinal)
    $finish = $text.IndexOf($End, [StringComparison]::Ordinal)
    Assert-CcodTrue ($begin -ge 0 -and $finish -gt $begin) 'the actual dependency import slice is present'
    Assert-CcodEqual $begin $text.LastIndexOf($Start, [StringComparison]::Ordinal) 'the import slice start is unique'
    return [scriptblock]::Create($text.Substring($begin, $finish - $begin))
}

Invoke-CcodImportTest 'Draft' 'draft acceptance dependency keeps file and ancestor authority through the real loader' {
    $fixture = New-CcodImportFixture
    $module = $null
    $imported = $null
    try {
        $directory = Join-Path (Split-Path $fixture.Tools -Parent) 'tests\installed'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $target = Join-Path $directory 'OfficialDraftAcceptance.psm1'
        [IO.File]::WriteAllText($target, 'function Get-CcodI8Origin { $PSScriptRoot }; Export-ModuleMember -Function Get-CcodI8Origin')
        $module = New-CcodImportDraftModule $fixture
        Set-CcodImportMutationTrap $module $target
        $slice = Get-CcodImportSlice (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.ps1') '$acceptanceModulePath = Join-Path' '$state = & $acceptanceModule'
        $imported = & $module { param($Slice,$toolRoot) . $Slice; return $acceptanceModule } $slice $fixture.Tools
        Assert-CcodImportMutationTrap $module
        Assert-CcodEqual $directory (& $imported { Get-CcodI8Origin }) 'acceptance import retains its real module path'
    } finally {
        if ($null -ne $imported) { Remove-Module $imported -Force -ErrorAction SilentlyContinue }
        if ($null -ne $module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

function Invoke-CcodImportFreshProcess {
    param([string]$Root,[string]$Body)
    $probe = Join-Path $Root ('probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($probe, ('$ErrorActionPreference = ''Stop''' + "`n" + $Body), [Text.UTF8Encoding]::new($false))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $probe + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); $process.WaitForExit(); throw 'fresh import probe timed out' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose(); [IO.File]::Delete($probe) }
}

function Get-CcodImportSelfMutationScript {
    return @'
$script:I8Blocked = 0
try { [IO.File]::WriteAllBytes($PSCommandPath, [IO.File]::ReadAllBytes($PSCommandPath)) } catch [IO.IOException] { $script:I8Blocked++ }
foreach ($directory in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent))) {
    try { [IO.Directory]::Move($directory, $directory + '-moved'); [IO.Directory]::Move($directory + '-moved', $directory) }
    catch [IO.IOException] { $script:I8Blocked++ }
}
function Get-CcodI8State { [pscustomobject]@{ Blocked = $script:I8Blocked; Root = $PSScriptRoot } }
'@
}

Invoke-CcodImportTest 'Wrapper' 'draft wrapper bootstraps in a fresh process and holds through dot sourced initialization' {
    $fixture = New-CcodImportFixture
    try {
        $wrapper = Join-Path $fixture.Tools 'Invoke-GitHubDraftRelease.psm1'
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tools\Invoke-GitHubDraftRelease.psm1') -Destination $wrapper
        $scriptPath = Join-Path $fixture.Tools 'Invoke-GitHubDraftRelease.ps1'
        [IO.File]::WriteAllText($scriptPath, (Get-CcodImportSelfMutationScript) + "`nfunction Invoke-CcodGitHubDraftRelease { Get-CcodI8State }", [Text.UTF8Encoding]::new($false))
        $body = @'
if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { throw 'probe was not fresh' }
$module = Import-Module '__WRAPPER__' -Force -PassThru
try {
    if ((@($module.ExportedCommands.Keys) -join ',') -cne 'Invoke-CcodGitHubDraftRelease') { throw 'unexpected public exports' }
    $state = Invoke-CcodGitHubDraftRelease
    if ($state.Blocked -ne 3) { throw ('import authority ended before initializer: blocked=' + $state.Blocked) }
    if ($state.Root -cne '__TOOLS__') { throw 'dot source root changed' }
} finally { Remove-Module $module -Force }
[IO.File]::WriteAllText('__SCRIPT__', '# released after dot source')
'@
        $body = $body.Replace('__WRAPPER__', $wrapper.Replace("'", "''")).Replace('__TOOLS__', $fixture.Tools.Replace("'", "''")).Replace('__SCRIPT__', $scriptPath.Replace("'", "''"))
        $result = Invoke-CcodImportFreshProcess $fixture.Root $body
        Assert-CcodEqual 0 $result.ExitCode ('fresh wrapper holds authority through initializer: ' + $result.Output)
    } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
}

Invoke-CcodImportTest 'Contract' 'standalone asset contract pins SetupArtifact through its actual import slice' {
    $fixture = New-CcodImportFixture
    $module = $null
    try {
        $source = Join-Path $repositoryRoot 'tools\ReleaseAssetContract.psm1'
        $copy = Join-Path $fixture.Tools 'ReleaseAssetContract.psm1'
        Copy-Item -LiteralPath $source -Destination $copy
        $build = Join-Path (Split-Path $fixture.Tools -Parent) 'build'
        [IO.Directory]::CreateDirectory($build) | Out-Null
        $target = Join-Path $build 'SetupArtifact.psm1'
        [IO.File]::WriteAllText($target, 'function Get-CcodI8Origin { $PSScriptRoot }; Export-ModuleMember -Function Get-CcodI8Origin')
        $module = Import-Module $copy -Force -PassThru -DisableNameChecking
        Set-CcodImportMutationTrap $module $target
        $slice = Get-CcodImportSlice $source '$setupModule=Join-Path' 'try{$setup=Test-CcodSetupArtifact'
        $slice = [scriptblock]::Create('param($PSScriptRoot)' + "`n" + $slice.ToString())
        & $module { param($Slice,$Tools) $ErrorId = 'CCOD_RELEASE_ASSET_SET_INVALID'; . $Slice $Tools } $slice $fixture.Tools
        Assert-CcodImportMutationTrap $module
        $imported = & $module { $script:I8Imported }
        Assert-CcodEqual $build (& $imported { Get-CcodI8Origin }) 'SetupArtifact module keeps its true root'
    } finally {
        if ($null -ne $module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
        Get-Module | Where-Object { $_.Path -and $_.Path.StartsWith($fixture.Root, [StringComparison]::OrdinalIgnoreCase) } | Remove-Module -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

foreach ($dependency in @(
    @{ Leaf = 'ReleaseAssetContract.psm1'; Getter = 'Get-CcodOfficialDraftAssetModule' },
    @{ Leaf = 'ReleaseDefender.psm1'; Getter = 'Get-CcodOfficialDraftDefenderModule' }
)) {
    Invoke-CcodImportTest 'Acceptance' ('standalone acceptance protects dependency ' + $dependency.Leaf) {
        $fixture = New-CcodImportFixture
        $module = $null
        $imported = $null
        try {
            $directory = Join-Path (Split-Path $fixture.Tools -Parent) 'tests\installed'
            [IO.Directory]::CreateDirectory($directory) | Out-Null
            $copy = Join-Path $directory 'OfficialDraftAcceptance.psm1'
            Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tests\installed\OfficialDraftAcceptance.psm1') -Destination $copy
            $target = Join-Path $fixture.Tools $dependency.Leaf
            [IO.File]::WriteAllText($target, 'function Get-CcodI8Origin { $PSScriptRoot }; Export-ModuleMember -Function Get-CcodI8Origin')
            $module = Import-Module $copy -Force -PassThru -DisableNameChecking
            Set-CcodImportMutationTrap $module $target
            $imported = & $module { param($Getter) & $Getter } $dependency.Getter
            Assert-CcodImportMutationTrap $module
            Assert-CcodEqual $fixture.Tools (& $imported { Get-CcodI8Origin }) 'dependency keeps its real root and module identity'
        } finally {
            if ($null -ne $imported) { Remove-Module $imported -Force -ErrorAction SilentlyContinue }
            if ($null -ne $module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CcodImportTest 'Acceptance' 'Defender dependency reimport is protected in a fresh process without running a scan' {
    $fixture = New-CcodImportFixture
    try {
        $entry = Join-Path $fixture.Tools 'ReleaseDefender.psm1'
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tools\ReleaseDefender.psm1') -Destination $entry
        $dependency = Join-Path $fixture.Tools 'ReleaseAssetContract.psm1'
        [IO.File]::WriteAllText($dependency, (Get-CcodImportSelfMutationScript) + "`nExport-ModuleMember -Function Get-CcodI8State", [Text.UTF8Encoding]::new($false))
        $body = @'
if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { throw 'probe was not fresh' }
$module = Import-Module '__ENTRY__' -Force -PassThru -DisableNameChecking
try {
    if ((@($module.ExportedCommands.Keys) -join ',') -cne 'Invoke-CcodReleaseDefenderCheck') { throw 'unexpected Defender exports' }
    $state = & $module { & $script:CcodReleaseAssetContractModule { Get-CcodI8State } }
    if ($state.Blocked -ne 3) { throw ('nested contract import was unprotected: blocked=' + $state.Blocked) }
} finally { Remove-Module $module -Force }
[IO.File]::WriteAllText('__DEPENDENCY__', '# released')
'@
        $result = Invoke-CcodImportFreshProcess $fixture.Root ($body.Replace('__ENTRY__', $entry.Replace("'", "''")).Replace('__DEPENDENCY__', $dependency.Replace("'", "''")))
        Assert-CcodEqual 0 $result.ExitCode ('nested dependency retains import authority: ' + $result.Output)
    } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
}

function Assert-CcodImportFixtureReleased {
    param($Fixture,[string]$Target)
    [IO.File]::WriteAllText($Target, '# lease released')
    foreach ($directory in @($Fixture.Tools, (Split-Path $Fixture.Tools -Parent), $Fixture.Root)) {
        [IO.Directory]::Move($directory, $directory + '-released')
        [IO.Directory]::Move($directory + '-released', $directory)
    }
}

Invoke-CcodImportTest 'Lease' 'preexisting writable handle rejects loading and releases every partially acquired ancestor' {
    $fixture = New-CcodImportFixture
    $module = New-CcodImportDraftModule $fixture
    $writer = $null
    try {
        $marker = Join-Path $fixture.Root 'unexpected-loader.txt'
        $target = Join-Path $fixture.Tools 'ReleaseAssetContract.psm1'
        [IO.File]::WriteAllText($target, "[IO.File]::WriteAllText('" + $marker.Replace("'", "''") + "', 'executed')")
        $writer = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $failure = $null
        try { & $module { param($Root) $script:CcodGitHubDraftModuleRoot = $Root; Import-CcodDraftReleaseAssetContract } $fixture.Tools } catch { $failure = $_ }
        Assert-CcodTrue ($null -ne $failure) 'existing writable access prevents acquisition rather than merely checking path twice'
        Assert-CcodEqual 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING' ($failure.FullyQualifiedErrorId.Split(',')[0]) 'caller keeps stable failure identity'
        Assert-CcodTrue (-not [IO.File]::Exists($marker)) 'no dependency code runs after failed acquisition'
        $writer.Dispose(); $writer = $null
        Assert-CcodImportFixtureReleased $fixture $target
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        Remove-Module $module -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

foreach ($failureKind in @('Initializer','Parser','Validation')) {
    Invoke-CcodImportTest 'Lease' ('real loader or validation failure releases leases: ' + $failureKind) {
        $fixture = New-CcodImportFixture
        $module = New-CcodImportDraftModule $fixture
        try {
            $target = Join-Path $fixture.Tools 'ReleaseAssetContract.psm1'
            $body = if ($failureKind -eq 'Parser') { 'function {' } elseif ($failureKind -eq 'Initializer') { "throw 'CCOD_I8_INITIALIZER_THROW'" } else { '# never execute' }
            [IO.File]::WriteAllText($target, $body)
            $failure = $null
            try {
                & $module {
                    param($Root,$Kind)
                    $script:CcodGitHubDraftModuleRoot = $Root
                    if ($Kind -eq 'Validation') { function Assert-CcodGitHubDraftTrustedModulePath { throw 'CCOD_I8_VALIDATION_THROW' } }
                    Import-CcodDraftReleaseAssetContract
                } $fixture.Tools $failureKind
            } catch { $failure = $_ }
            Assert-CcodTrue ($null -ne $failure) 'probe actually reaches a terminal failure'
            if ($failureKind -ne 'Parser') { Assert-CcodTrue ($failure.Exception.Message -match ('CCOD_I8_' + $failureKind.ToUpperInvariant() + '_THROW')) 'the intended failure boundary was reached' }
            else { Assert-CcodTrue ($failure.FullyQualifiedErrorId -notlike 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING*') 'parser failure occurs after successful acquisition' }
            Assert-CcodImportFixtureReleased $fixture $target
        } finally {
            Remove-Module $module -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force
        }
    }
}

Invoke-CcodImportTest 'Lease' 'lease rejects junction ancestry without executing target and releases the junction handle' {
    $fixture = New-CcodImportFixture
    $module = New-CcodImportDraftModule $fixture
    $junction = Join-Path $fixture.Root 'alias'
    try {
        $target = Join-Path $fixture.Tools 'ReleaseAssetContract.psm1'
        [IO.File]::WriteAllText($target, '# innocent module')
        New-Item -ItemType Junction -Path $junction -Target $fixture.Tools | Out-Null
        $failure = $null
        try { & $module { param($Root) $script:CcodGitHubDraftModuleRoot = $Root; Import-CcodDraftReleaseAssetContract } $junction } catch { $failure = $_ }
        Assert-CcodTrue ($null -ne $failure) 'junction ancestry fails closed'
        Assert-CcodEqual 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING' ($failure.FullyQualifiedErrorId.Split(',')[0]) 'junction failure remains classified'
        [IO.Directory]::Delete($junction)
        Assert-CcodImportFixtureReleased $fixture $target
    } finally {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
        if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

Invoke-CcodImportTest 'Lease' 'all owned ancestors remain held until dispose and dispose is idempotent' {
    $fixture = New-CcodImportFixture
    $module = New-CcodImportDraftModule $fixture
    $lease = $null
    try {
        $target = Join-Path $fixture.Tools 'probe.psm1'
        [IO.File]::WriteAllText($target, '# probe')
        $lease = & $module { param($Target) Open-CcodTrustedImportLease -Path $Target -ErrorId 'CCOD_I8_LEASE_FAILED' } $target
        foreach ($directory in @($fixture.Tools, (Split-Path $fixture.Tools -Parent), $fixture.Root)) {
            $denied = $false
            try { [IO.Directory]::Move($directory, $directory + '-moved'); [IO.Directory]::Move($directory + '-moved', $directory) } catch [IO.IOException] { $denied = $true }
            Assert-CcodTrue $denied 'even the fixture ancestor above the repository is held'
        }
        $lease.Revalidate(); $lease.Dispose(); $lease.Dispose()
        $failure = $null
        try { $lease.Revalidate() } catch { $failure = $_ }
        Assert-CcodTrue ($null -ne $failure) 'disposed authority cannot be reused'
        Assert-CcodImportFixtureReleased $fixture $target
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        Remove-Module $module -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

$bootstrapEntries = @('tools\Invoke-GitHubDraftRelease.ps1','tools\Invoke-GitHubDraftRelease.psm1','tools\ReleaseAssetContract.psm1','tools\ReleaseDefender.psm1','tests\installed\OfficialDraftAcceptance.psm1')
Invoke-CcodImportTest 'Lease' 'independently trusted entrypoints embed identical bootstrap code' {
    $expected = $null
    foreach ($entry in ($bootstrapEntries + @('tests\installed\Invoke-OfficialDraftAcceptance.ps1','tools\Test-ReleaseDefender.ps1','tests\installed\Invoke-InstalledLifecycleIntegration.ps1'))) {
        $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot $entry))
        $matches = [regex]::Matches($text, '(?s)# BEGIN CCOD TRUSTED IMPORT BOOTSTRAP.*?# END CCOD TRUSTED IMPORT BOOTSTRAP')
        Assert-CcodEqual 1 $matches.Count ('exactly one locally trusted bootstrap: ' + $entry)
        $current = $matches[0].Value.Replace("`r`n", "`n")
        if ($null -eq $expected) { $expected = $current }
        else { Assert-CcodEqual $expected $current ('bootstrap copies must not drift: ' + $entry) }
    }
}

foreach ($entry in $bootstrapEntries) {
    Invoke-CcodImportTest 'Lease' ('bootstrap does not depend on prior imports in Windows PowerShell 5.1: ' + $entry) {
        $fixture = New-CcodImportFixture
        try {
            $target = Join-Path $fixture.Tools 'probe.psm1'
            [IO.File]::WriteAllText($target, '# benign probe')
            $body = @'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'not Windows PowerShell 5.1' }
if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { throw 'probe was not fresh' }
$entry = '__ENTRY__'
if ([IO.Path]::GetExtension($entry) -eq '.ps1') { $module = New-Module -ArgumentList $entry -ScriptBlock { param($Path) . $Path } }
else { $module = Import-Module $entry -Force -PassThru -DisableNameChecking }
& $module { Initialize-CcodTrustedImportLease }
$lease = [CcodTrustedImportLeaseV1]::Acquire('__TARGET__')
try { $lease.Revalidate() } finally { $lease.Dispose() }
[IO.File]::WriteAllText('__TARGET__', '# released')
'@
            $body = $body.Replace('__ENTRY__', (Join-Path $repositoryRoot $entry).Replace("'", "''")).Replace('__TARGET__', $target.Replace("'", "''"))
            $result = Invoke-CcodImportFreshProcess $fixture.Root $body
            Assert-CcodEqual 0 $result.ExitCode ('each entry bootstraps independently: ' + $result.Output)
        } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

foreach ($wrapper in @(
    @{ Entry = 'tests\installed\Invoke-OfficialDraftAcceptance.ps1'; Leaf = 'OfficialDraftAcceptance.psm1'; Command = 'Invoke-CcodOfficialDraftAcceptance'; Arguments = "@{ Phase='Preflight'; AssetDirectory='unused'; PreviousAssetDirectory='unused'; EvidenceRoot='unused' }"; Parameters = 'Phase,AssetDirectory,PreviousAssetDirectory,EvidenceRoot,DraftId,AllowMachineMutation,AllowCodexRestart,AllowWindowsReboot' },
    @{ Entry = 'tools\Test-ReleaseDefender.ps1'; Leaf = 'ReleaseDefender.psm1'; Command = 'Invoke-CcodReleaseDefenderCheck'; Arguments = "@{ CandidatePath='unused'; ChecksumPath='unused'; ManifestPath='unused'; Origin='InternetDownload'; ExpectedVersion='2.5.22'; ExpectedGitCommit=('c'*40); EvidencePath='unused' }"; Parameters = 'CandidatePath,ChecksumPath,ManifestPath,Origin,WorkflowArtifactIdentity,ExpectedVersion,ExpectedGitCommit,EvidencePath' }
)) {
    Invoke-CcodImportTest 'Wrapper' ('public wrapper protects first dependency in a fresh process: ' + $wrapper.Entry) {
        $fixture = New-CcodImportFixture
        try {
            $entry = Join-Path $fixture.Tools ([IO.Path]::GetFileName($wrapper.Entry))
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $wrapper.Entry) -Destination $entry
            $parameters = @($wrapper.Parameters.Split(',') | ForEach-Object { '$' + $_ }) -join ','
            $fixtureCommand = 'function ' + $wrapper.Command + ' { param(' + $parameters + '); $state=Get-CcodI8State; [pscustomobject]@{ I8Fixture=''no scan or machine mutation''; Blocked=$state.Blocked } }; Export-ModuleMember -Function ' + $wrapper.Command
            $dependency = Join-Path $fixture.Tools $wrapper.Leaf
            [IO.File]::WriteAllText($dependency, (Get-CcodImportSelfMutationScript) + "`n" + $fixtureCommand, [Text.UTF8Encoding]::new($false))
            $body = @'
if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { throw 'probe was not fresh' }
$arguments = __ARGUMENTS__
$result = & '__ENTRY__' @arguments | ConvertFrom-Json
if ($result.I8Fixture -cne 'no scan or machine mutation' -or $result.Blocked -ne 3) { throw ('public wrapper load was unprotected: blocked=' + $result.Blocked) }
[IO.File]::WriteAllText('__DEPENDENCY__', '# released')
'@
            $body = $body.Replace('__ENTRY__', $entry.Replace("'", "''")).Replace('__DEPENDENCY__', $dependency.Replace("'", "''")).Replace('__ARGUMENTS__', $wrapper.Arguments)
            $result = Invoke-CcodImportFreshProcess $fixture.Root $body
            Assert-CcodEqual 0 $result.ExitCode ('public first dependency authority: ' + $result.Output)
        } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodImportTest 'Acceptance' 'acceptance holds its integration library script through dot sourced initialization' {
    $fixture = New-CcodImportFixture
    $module = $null
    $library = $null
    try {
        $directory = Join-Path (Split-Path $fixture.Tools -Parent) 'tests\installed'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $copy = Join-Path $directory 'OfficialDraftAcceptance.psm1'
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tests\installed\OfficialDraftAcceptance.psm1') -Destination $copy
        $target = Join-Path $directory 'Invoke-InstalledLifecycleIntegration.ps1'
        [IO.File]::WriteAllText($target, ('param([switch]$Library)' + "`n" + (Get-CcodImportSelfMutationScript)), [Text.UTF8Encoding]::new($false))
        $module = Import-Module $copy -Force -PassThru -DisableNameChecking
        $library = & $module { Get-CcodOfficialDraftIntegrationModule }
        $state = & $library { Get-CcodI8State }
        Assert-CcodEqual 3 $state.Blocked 'existing New-Module dot source keeps authority until initialization ends'
        Assert-CcodEqual $directory $state.Root 'integration library keeps original script root'
        [IO.File]::WriteAllText($target, '# released after library load')
    } finally {
        if ($null -ne $library) { Remove-Module $library -Force -ErrorAction SilentlyContinue }
        if ($null -ne $module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

Invoke-CcodImportTest 'Acceptance' 'integration library retains its complete eager dependency closure through nested imports' {
    $fixture = New-CcodImportFixture
    try {
        $repo = Split-Path $fixture.Tools -Parent
        $installed = Join-Path $repo 'tests\installed'
        $modules = Join-Path $repo 'src\persistence\modules'
        [IO.Directory]::CreateDirectory($installed) | Out-Null
        [IO.Directory]::CreateDirectory($modules) | Out-Null
        $entry = Join-Path $installed 'Invoke-InstalledLifecycleIntegration.ps1'
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tests\installed\Invoke-InstalledLifecycleIntegration.ps1') -Destination $entry
        $names = @('PersistenceIO.psm1','StateStore.psm1','TrustedLogonIdentity.psm1','LifecycleTransaction.psm1')
        foreach ($name in $names) {
            $nested = if ($name -eq 'StateStore.psm1') { "Import-Module (Join-Path `$PSScriptRoot 'TrustedLogonIdentity.psm1') -Force`n" } else { '' }
            [IO.File]::WriteAllText((Join-Path $modules $name), ($nested + (Get-CcodImportSelfMutationScript) + "`nExport-ModuleMember -Function Get-CcodI8State"), [Text.UTF8Encoding]::new($false))
        }
        $body = @'
if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { throw 'probe was not fresh' }
$library = New-Module -ArgumentList '__ENTRY__' -ScriptBlock { param($Path) . $Path -Library }
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($module in @(Get-Module -All | Where-Object { $_.Path -and $_.Path.StartsWith('__MODULES__', [StringComparison]::OrdinalIgnoreCase) })) {
    [void]$paths.Add($module.Path)
    $state = & $module { Get-CcodI8State }
    if ($state.Blocked -ne 3) { throw ('eager dependency not held: ' + $module.Name + ' blocked=' + $state.Blocked) }
}
if ($paths.Count -ne 4) { throw 'nested dependency probe did not execute the complete eager closure' }
foreach ($path in $paths) { [IO.File]::WriteAllText($path, '# released') }
'@
        $result = Invoke-CcodImportFreshProcess $fixture.Root ($body.Replace('__ENTRY__', $entry.Replace("'", "''")).Replace('__MODULES__', $modules.Replace("'", "''")))
        Assert-CcodEqual 0 $result.ExitCode ('all eager and nested dependencies protected: ' + $result.Output)
    } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
}

Invoke-CcodImportTest 'Lease' 'integration eager import graph cannot grow beyond its pinned closure unnoticed' {
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue((Join-Path $repositoryRoot 'tests\installed\Invoke-InstalledLifecycleIntegration.ps1'))
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $declared = $null
    while ($queue.Count -gt 0) {
        $path = $queue.Dequeue()
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        Assert-CcodEqual 0 @($parseErrors).Count 'dependency graph source parses'
        if ($null -eq $declared) {
            $assignment = @($ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -ceq '$importClosure' }, $true))
            Assert-CcodEqual 1 $assignment.Count 'one explicit import closure'
            $declared = @($assignment[0].Right.FindAll({ param($Node) $Node -is [Management.Automation.Language.StringConstantExpressionAst] -and $Node.Value.EndsWith('.psm1') }, $true) | ForEach-Object Value)
        }
        foreach ($command in @($ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Import-Module' }, $true))) {
            $parent = $command.Parent
            while ($null -ne $parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
            if ($null -ne $parent) { continue }
            $literals = @($command.FindAll({ param($Node) $Node -is [Management.Automation.Language.StringConstantExpressionAst] -and $Node.Value.EndsWith('.psm1') }, $true))
            Assert-CcodEqual 1 $literals.Count 'every eager import has one statically auditable dependency'
            $leaf = [IO.Path]::GetFileName($literals[0].Value)
            if ($observed.Add($leaf)) { $queue.Enqueue((Join-Path (Join-Path $repositoryRoot 'src\persistence\modules') $leaf)) }
        }
    }
    Assert-CcodEqual (($declared | Sort-Object) -join ',') ((@($observed) | Sort-Object) -join ',') 'lease set exactly covers actual transitive eager imports'
}

Invoke-CcodImportTest 'Lease' 'main validation requires the import regression harness instead of silently dropping it' {
    $validation = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'tests\Validate.ps1'))
    Assert-CcodTrue $validation.Contains("'tests\persistence\TrustedModuleImport.SelfTest.ps1'") 'main validation must require the I8 self-test file'
    $discovered = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.SelfTest.ps1' | Where-Object Name -CEQ 'TrustedModuleImport.SelfTest.ps1')
    Assert-CcodEqual 1 $discovered.Count 'serial persistence discovery registers the harness once'
}

if ($script:executed -eq 0) { throw 'CCOD_IMPORT_TEST_SELECTION_INVALID' }
if ($Case) { Write-Host "CCOD_IMPORT_FOCUSED_PASSED area=$Case executed=$script:executed skipped=$script:skipped" }
else { Write-Host "Trusted module import self-tests passed: $script:executed; skipped=$script:skipped." }
