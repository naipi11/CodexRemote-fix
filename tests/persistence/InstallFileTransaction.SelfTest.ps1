$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $projectRoot 'src\persistence\modules\InstallFileTransaction.psm1'
$module = $null
if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
}

if ($null -eq ('CcodInstallTransactionTestNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public static class CcodInstallTransactionTestNative
{
    private const uint FILE_LIST_DIRECTORY = 0x00000001;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint DELETE = 0x00010000;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(string newName, string existingName, IntPtr securityAttributes);

    public static int CreateHardLink(string newName, string existingName)
    {
        return CreateHardLinkW(newName, existingName, IntPtr.Zero) ? 0 : Marshal.GetLastWin32Error();
    }

    public static SafeFileHandle OpenDirectoryAllowDeleteShare(string path)
    {
        SafeFileHandle handle = CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }

    public static int TryOpenDirectoryForChildWrite(string path)
    {
        using (SafeFileHandle handle = CreateFileW(path, 0x00000002 | 0x00000004 | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero))
        {
            return handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        }
    }

    public static SafeFileHandle OpenFileAllowDeleteShare(string path)
    {
        SafeFileHandle handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }

    public static Task<string> InsertUnknownWhenLeafBecomesUnavailable(string watchedLeaf, string unknownLeaf)
    {
        return Task.Run(() => {
            DateTime deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline)
            {
                if (!File.Exists(watchedLeaf))
                {
                    try { File.WriteAllText(unknownLeaf, "concurrent-unknown"); return "inserted"; }
                    catch (IOException) { return "blocked"; }
                    catch (UnauthorizedAccessException) { return "blocked"; }
                }
                Thread.Yield();
            }
            return "timeout";
        });
    }

    public static Task<string> InsertUnknownAfterDelay(string unknownLeaf, int delayMilliseconds)
    {
        return Task.Run(() => {
            Thread.Sleep(delayMilliseconds);
            try { File.WriteAllText(unknownLeaf, "concurrent-unknown"); return "inserted"; }
            catch (IOException) { return "blocked"; }
            catch (UnauthorizedAccessException) { return "blocked"; }
        });
    }
}
'@
}

function Invoke-CcodInstallModule {
    param([Parameter(Mandatory)][scriptblock]$Action, [object[]]$Arguments = @())
    if ($null -eq $module) { return & $Action @Arguments }
    return & $module $Action @Arguments
}

function New-CcodInstallFileFixture {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('ccod-install-file-' + [guid]::NewGuid().ToString('N'))
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-install-outside-' + [guid]::NewGuid().ToString('N'))
    $install = Join-Path $base 'install'
    [IO.Directory]::CreateDirectory($install) | Out-Null
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $sentinel = Join-Path $outside 'sentinel.txt'
    $sentinelBytes = [Text.UTF8Encoding]::new($false).GetBytes('outside-sentinel-v1')
    [IO.File]::WriteAllBytes($sentinel, $sentinelBytes)
    return [pscustomobject]@{
        Base = $base
        MovedBase = $null
        Install = $install
        Outside = $outside
        Sentinel = $sentinel
        SentinelSha256 = Get-CcodTestFileSha256 -Path $sentinel
        Transaction = $null
    }
}

function Assert-CcodOutsideUnchanged {
    param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Message)
    Assert-CcodTrue ([IO.File]::Exists($Fixture.Sentinel)) "$Message sentinel exists"
    Assert-CcodEqual $Fixture.SentinelSha256 (Get-CcodTestFileSha256 -Path $Fixture.Sentinel) "$Message sentinel bytes"
}

function Close-CcodFixtureTransaction {
    param([Parameter(Mandatory)]$Fixture)
    if ($null -eq $Fixture.Transaction) { return }
    try {
        Invoke-CcodInstallModule { param($Tx) Close-CcodInstallFileTransaction -Transaction $Tx -Disposition Failed } @($Fixture.Transaction) | Out-Null
    } catch { }
    $Fixture.Transaction = $null
}

function Remove-CcodInstallFileFixture {
    param([Parameter(Mandatory)]$Fixture)
    Close-CcodFixtureTransaction -Fixture $Fixture
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    foreach ($candidate in @($Fixture.Base, $Fixture.MovedBase, $Fixture.Outside)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        $full = [IO.Path]::GetFullPath([string]$candidate)
        if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove non-temporary fixture path: $full"
        }
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    }
}

function Open-CcodFixtureTransaction {
    param([Parameter(Mandatory)]$Fixture)
    $Fixture.Transaction = Invoke-CcodInstallModule { param($Install) Open-CcodInstallFileTransaction -InstallRoot $Install } @($Fixture.Install)
    return $Fixture.Transaction
}

function Invoke-CcodAttemptDirectoryReplacement {
    param([Parameter(Mandatory)][string]$Path)
    $backup = $Path + '.attacker-old'
    try {
        [IO.Directory]::Move($Path, $backup)
        return [pscustomobject]@{ Outcome = 'replaced'; Backup = $backup }
    } catch [IO.IOException] {
        return [pscustomobject]@{ Outcome = 'blocked'; Backup = $null }
    } catch [UnauthorizedAccessException] {
        return [pscustomobject]@{ Outcome = 'blocked'; Backup = $null }
    }
}

function Invoke-CcodAttemptFileReplacement {
    param([Parameter(Mandatory)][string]$Path)
    $backup = $Path + '.attacker-old'
    try {
        [IO.File]::Move($Path, $backup)
        return [pscustomobject]@{ Outcome = 'replaced'; Backup = $backup }
    } catch [IO.IOException] {
        return [pscustomobject]@{ Outcome = 'blocked'; Backup = $null }
    } catch [UnauthorizedAccessException] {
        return [pscustomobject]@{ Outcome = 'blocked'; Backup = $null }
    }
}

function Invoke-CcodReplacePinnedDirectory {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$Path
    )
    $moved = $Path + '.attacker-old'
    try {
        [IO.Directory]::Move($Path, $moved)
    } catch [IO.IOException] {
        return [pscustomobject]@{ Outcome = 'blocked'; MovedDirectory = $null }
    } catch [UnauthorizedAccessException] {
        return [pscustomobject]@{ Outcome = 'blocked'; MovedDirectory = $null }
    }
    $result = & cmd.exe /d /c mklink /J $Path $Fixture.Outside 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not create replacement junction: $result" }
    return [pscustomobject]@{ Outcome = 'replaced'; MovedDirectory = $moved }
}

function New-CcodHardLink {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Existing)
    $errorCode = [CcodInstallTransactionTestNative]::CreateHardLink($Path, $Existing)
    if ($errorCode -ne 0) { throw "CreateHardLink failed with Windows error $errorCode" }
}

function New-CcodJunction {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $result = & cmd.exe /d /c mklink /J $Path $Target 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not create junction: $result" }
}

function Invoke-CcodAttemptAdsWrite {
    param([Parameter(Mandatory)][string]$Path)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & cmd.exe /d /c "echo attacker>`"$Path`"" 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Outcome = $(if ($exitCode -eq 0) { 'created' } else { 'blocked' }); Output = $output }
}

function New-CcodSourceFile {
    param([Parameter(Mandatory)]$Fixture, [string]$Name = 'source.bin', [string]$Content = 'sealed-source-v1')
    $path = Join-Path $Fixture.Base $Name
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    [IO.File]::WriteAllBytes($path, $bytes)
    return [pscustomobject]@{ Path = $path; Length = [int64]$bytes.LongLength; Sha256 = Get-CcodTestFileSha256 -Path $path }
}

Invoke-CcodTest 'pins a newly created child directory against pathname replacement' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $child = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'runtime' -CreateIfMissing } @($tx)
        $result = Invoke-CcodAttemptDirectoryReplacement -Path (Join-Path $fixture.Install 'runtime')
        Assert-CcodEqual 'blocked' $result.Outcome 'pinned missing directory cannot be replaced after creation'
        Assert-CcodOutsideUnchanged $fixture 'directory replacement'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'pins a temporary leaf against replacement before promotion' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $runtime = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'runtime' -CreateIfMissing } @($tx)
        $temporary = Invoke-CcodInstallModule { param($Tx,$Parent) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Parent -Leaf 'payload.tmp' } @($tx,$runtime)
        $result = Invoke-CcodAttemptFileReplacement -Path (Join-Path $fixture.Install 'runtime\payload.tmp')
        Assert-CcodEqual 'blocked' $result.Outcome 'temporary leaf replacement is blocked while pinned'
        Assert-CcodOutsideUnchanged $fixture 'temporary replacement'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'pins sealed source bytes while copying and verifies the destination handle' {
    $fixture = New-CcodInstallFileFixture
    try {
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $runtime = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'runtime' -CreateIfMissing } @($tx)
        $temporary = Invoke-CcodInstallModule { param($Tx,$Parent) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Parent -Leaf 'payload.tmp' } @($tx,$runtime)
        $copy = Invoke-CcodInstallModule {
            param($Tx,$Source,$Leaf,$Length,$Sha)
            Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha
        } @($tx,$source.Path,$temporary,$source.Length,$source.Sha256)
        Assert-CcodEqual $source.Length $copy.Length 'copied length is sealed'
        Assert-CcodEqual $source.Sha256 $copy.Sha256 'copied digest is sealed'
        Assert-CcodOutsideUnchanged $fixture 'source replacement'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'rejects reparse ADS and multi-link leaf inputs' {
    $fixture = New-CcodInstallFileFixture
    try {
        New-CcodJunction -Path (Join-Path $fixture.Install 'linked') -Target $fixture.Outside
        $tx = Open-CcodFixtureTransaction $fixture
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'linked' } @($tx) | Out-Null
        } 'CCOD_INSTALL_REPARSE_LEAF'
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'payload.tmp:ads' } @($tx) | Out-Null
        } 'CCOD_INSTALL_LEAF_INVALID'

        $source = New-CcodSourceFile $fixture
        New-CcodHardLink -Path (Join-Path $fixture.Base 'source-hardlink.bin') -Existing $source.Path
        $temporary = Invoke-CcodInstallModule { param($Tx) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'payload.tmp' } @($tx)
        Assert-CcodThrows {
            Invoke-CcodInstallModule {
                param($Tx,$Source,$Leaf,$Length,$Sha)
                Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha
            } @($tx,$source.Path,$temporary,$source.Length,$source.Sha256) | Out-Null
        } 'CCOD_INSTALL_MULTILINK_LEAF'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $fixture.Install 'payload.tmp'))) 'rejected multi-link source retains the owned temporary candidate'
        Assert-CcodOutsideUnchanged $fixture 'invalid leaves'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'rejects an existing ADS-bearing promotion destination without replacement' {
    $fixture = New-CcodInstallFileFixture
    try {
        $destination = Join-Path $fixture.Install 'active.json'
        [IO.File]::WriteAllText($destination, 'old')
        $adsResult = & cmd.exe /d /c "echo attacker>`"$destination`:metadata`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create alternate data stream: $adsResult" }
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $temporary = Invoke-CcodInstallModule { param($Tx) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'active.tmp' } @($tx)
        Invoke-CcodInstallModule {
            param($Tx,$Source,$Leaf,$Length,$Sha)
            Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha | Out-Null
        } @($tx,$source.Path,$temporary,$source.Length,$source.Sha256)
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx,$Leaf) Commit-CcodInstallPinnedPromotion -Transaction $Tx -ParentDirectory $Tx.RootDirectory -TemporaryLeaf $Leaf -DestinationLeaf 'active.json' } @($tx,$temporary) | Out-Null
        } 'CCOD_INSTALL_PROMOTION_DESTINATION_EXISTS'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $fixture.Install 'active.tmp'))) 'failed ADS promotion retains the temporary candidate'
        Assert-CcodOutsideUnchanged $fixture 'ADS destination'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'rejects promotion after an ancestor rename changes the pinned parent path' {
    $fixture = New-CcodInstallFileFixture
    try {
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $runtime = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'runtime' -CreateIfMissing } @($tx)
        $temporary = Invoke-CcodInstallModule { param($Tx,$Parent) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Parent -Leaf 'payload.tmp' } @($tx,$runtime)
        Invoke-CcodInstallModule {
            param($Tx,$Source,$Leaf,$Length,$Sha)
            Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha | Out-Null
        } @($tx,$source.Path,$temporary,$source.Length,$source.Sha256)
        $attack = Invoke-CcodReplacePinnedDirectory -Fixture $fixture -Path (Join-Path $fixture.Install 'runtime')
        if ($attack.Outcome -ceq 'replaced') {
            Assert-CcodThrows {
                Invoke-CcodInstallModule { param($Tx,$Parent,$Leaf) Commit-CcodInstallPinnedPromotion -Transaction $Tx -ParentDirectory $Parent -TemporaryLeaf $Leaf -DestinationLeaf 'payload.bin' } @($tx,$runtime,$temporary) | Out-Null
            } 'CCOD_INSTALL_PIN_CHANGED'
            Assert-CcodTrue ([IO.File]::Exists((Join-Path $attack.MovedDirectory 'payload.tmp'))) 'renamed-parent promotion retains its temporary candidate'
        } else {
            Invoke-CcodInstallModule { param($Tx,$Parent,$Leaf) Commit-CcodInstallPinnedPromotion -Transaction $Tx -ParentDirectory $Parent -TemporaryLeaf $Leaf -DestinationLeaf 'payload.bin' } @($tx,$runtime,$temporary) | Out-Null
            Close-CcodInstallFileTransaction -Transaction $tx -Disposition Ready | Out-Null
            $fixture.Transaction = $null
            Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 (Join-Path $fixture.Install 'runtime\payload.bin')) 'blocked parent rename promotes only sealed bytes'
        }
        Assert-CcodOutsideUnchanged $fixture 'renamed parent promotion'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

foreach ($case in @('unknown','reparse','multilink')) {
    Invoke-CcodTest "retains an owned tree containing an unproven $case leaf" {
        $fixture = New-CcodInstallFileFixture
        try {
            $tx = Open-CcodFixtureTransaction $fixture
            $candidate = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'candidate' -CreateIfMissing } @($tx)
            switch ($case) {
                'unknown' { [IO.File]::WriteAllText((Join-Path $fixture.Install 'candidate\surprise.bin'), 'unknown') }
                'reparse' { New-CcodJunction -Path (Join-Path $fixture.Install 'candidate\outside-link') -Target $fixture.Outside }
                'multilink' {
                    $owned = Invoke-CcodInstallModule { param($Tx,$Parent) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Parent -Leaf 'owned.tmp' } @($tx,$candidate)
                    New-CcodHardLink -Path (Join-Path $fixture.Outside 'owned-hardlink.tmp') -Existing (Join-Path $fixture.Install 'candidate\owned.tmp')
                }
            }
            $expected = switch ($case) {
                'unknown' { 'CCOD_INSTALL_UNKNOWN_LEAF' }
                'reparse' { 'CCOD_INSTALL_REPARSE_LEAF' }
                'multilink' { 'CCOD_INSTALL_MULTILINK_LEAF' }
            }
            Assert-CcodThrows {
                Invoke-CcodInstallModule { param($Tx) Remove-CcodInstallOwnedTree -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'candidate' } @($tx) | Out-Null
            } $expected
            Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install 'candidate'))) "failed $case cleanup retains the candidate directory"
            Assert-CcodOutsideUnchanged $fixture "$case cleanup"
        } finally { Remove-CcodInstallFileFixture $fixture }
    }
}

Invoke-CcodTest 'fails closed when a nonempty owned tree cannot establish every delete disposition' {
    $fixture = New-CcodInstallFileFixture
    try {
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'candidate' -CreateIfMissing } @($tx)
        $temporary = Invoke-CcodInstallModule { param($Tx,$Parent) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Parent -Leaf 'payload.tmp' } @($tx,$candidate)
        Invoke-CcodInstallModule {
            param($Tx,$Source,$Parent,$Leaf,$Length,$Sha)
            Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha | Out-Null
            Commit-CcodInstallPinnedPromotion -Transaction $Tx -ParentDirectory $Parent -TemporaryLeaf $Leaf -DestinationLeaf 'payload.bin' | Out-Null
        } @($tx,$source.Path,$candidate,$temporary,$source.Length,$source.Sha256)
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx) Remove-CcodInstallOwnedTree -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'candidate' } @($tx) | Out-Null
        } 'CCOD_INSTALL_DELETE_FAILED'
        Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install 'candidate'))) 'failed root disposition retains the owned directory'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $fixture.Install 'candidate\payload.bin'))) 'failed root disposition clears the prior file disposition'
        Assert-CcodOutsideUnchanged $fixture 'owned tree removal'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'deletes an empty fully-owned candidate after establishing its root disposition' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'empty-candidate' -CreateIfMissing
        Remove-CcodInstallOwnedTree -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'empty-candidate'
        Assert-CcodTrue (-not [IO.Directory]::Exists((Join-Path $fixture.Install 'empty-candidate'))) 'empty owned candidate is deleted only after its root disposition is established'
        Assert-CcodOutsideUnchanged $fixture 'empty owned tree removal'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

foreach ($case in @('json','log')) {
    Invoke-CcodTest "rejects a pinned $case write after parent pathname replacement" {
        $fixture = New-CcodInstallFileFixture
        try {
            $tx = Open-CcodFixtureTransaction $fixture
            $parent = Invoke-CcodInstallModule { param($Tx,$Leaf) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf $Leaf -CreateIfMissing } @($tx,$case)
            $attack = Invoke-CcodReplacePinnedDirectory -Fixture $fixture -Path (Join-Path $fixture.Install $case)
            if ($case -ceq 'json') {
                if ($attack.Outcome -ceq 'replaced') {
                    Assert-CcodThrows { Invoke-CcodInstallModule { param($Tx,$Parent) Write-CcodInstallPinnedJson -Transaction $Tx -ParentDirectory $Parent -Leaf 'state.json' -Value ([ordered]@{ schemaVersion = 1; value = 'safe' }) -Compress } @($tx,$parent) } 'CCOD_INSTALL_PIN_CHANGED'
                } else {
                    Invoke-CcodInstallModule { param($Tx,$Parent) Write-CcodInstallPinnedJson -Transaction $Tx -ParentDirectory $Parent -Leaf 'state.json' -Value ([ordered]@{ schemaVersion = 1; value = 'safe' }) -Compress } @($tx,$parent) | Out-Null
                }
                Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $fixture.Outside 'state.json'))) 'replaced JSON path is untouched'
            } else {
                if ($attack.Outcome -ceq 'replaced') {
                    Assert-CcodThrows { Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'safe'; code = 'CCOD_TEST' }) } @($tx,$parent) } 'CCOD_INSTALL_PIN_CHANGED'
                } else {
                    Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'safe'; code = 'CCOD_TEST' }) } @($tx,$parent) | Out-Null
                }
                Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $fixture.Outside 'install.log'))) 'replaced log path is untouched'
            }
            Assert-CcodOutsideUnchanged $fixture "replaced $case parent"
        } finally { Remove-CcodInstallFileFixture $fixture }
    }
}

Invoke-CcodTest 'writes pinned JSON and appends sanitized records through relative handles' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $state = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'state' -CreateIfMissing } @($tx)
        $logs = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'logs' -CreateIfMissing } @($tx)
        Invoke-CcodInstallModule { param($Tx,$Parent) Write-CcodInstallPinnedJson -Transaction $Tx -ParentDirectory $Parent -Leaf 'active.json' -Value ([ordered]@{ schemaVersion = 1; active = 'runtime-a' }) -Compress } @($tx,$state) | Out-Null
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx,$Parent) Write-CcodInstallPinnedJson -Transaction $Tx -ParentDirectory $Parent -Leaf 'active.json' -Value ([ordered]@{ schemaVersion = 1; active = 'runtime-b' }) -Compress } @($tx,$state) | Out-Null
        } 'CCOD_INSTALL_PROMOTION_DESTINATION_EXISTS'
        Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'one'; code = 'CCOD_OK' }) } @($tx,$logs) | Out-Null
        Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'two'; code = 'CCOD_READY' }) } @($tx,$logs) | Out-Null
        Invoke-CcodInstallModule { param($Tx) Close-CcodInstallFileTransaction -Transaction $Tx -Disposition Ready } @($tx) | Out-Null
        $fixture.Transaction = $null

        $json = [IO.File]::ReadAllText((Join-Path $fixture.Install 'state\active.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        Assert-CcodEqual 'runtime-a' $json.active 'no-replace pinned JSON preserves the first committed object'
        $records = @([IO.File]::ReadAllLines((Join-Path $fixture.Install 'logs\install.log'), [Text.UTF8Encoding]::new($false)))
        Assert-CcodEqual 2 $records.Count 'pinned log appends one JSON line per record'
        Assert-CcodEqual 'one' (($records[0] | ConvertFrom-Json).event) 'first log record is retained'
        Assert-CcodEqual 'two' (($records[1] | ConvertFrom-Json).event) 'second log record is appended'
        Assert-CcodOutsideUnchanged $fixture 'successful pinned writers'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'exports only the private transaction surface and closes on a terminal disposition' {
    $fixture = New-CcodInstallFileFixture
    try {
        $expectedExports = @(
            'Append-CcodInstallPinnedLog','Close-CcodInstallFileTransaction','Commit-CcodInstallPinnedPromotion',
            'Copy-CcodInstallSealedFile','New-CcodInstallPinnedTemporaryLeaf','Open-CcodInstallFileTransaction',
            'Open-CcodInstallPinnedDirectory','Remove-CcodInstallOwnedTree','Write-CcodInstallPinnedJson'
        )
        $actualExports = @($module.ExportedFunctions.Keys | Sort-Object)
        Assert-CcodEqual ($expectedExports -join ',') ($actualExports -join ',') 'module exports only the approved private transaction surface'
        $tx = Open-CcodFixtureTransaction $fixture
        Invoke-CcodInstallModule { param($Tx) Close-CcodInstallFileTransaction -Transaction $Tx -Disposition Ready } @($tx) | Out-Null
        $fixture.Transaction = $null
        Assert-CcodEqual 'RootDirectory' (@($tx.PSObject.Properties.Name) -join ',') 'terminal transaction remains opaque'
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'after-close' -CreateIfMissing } @($tx) | Out-Null
        } 'CCOD_INSTALL_TRANSACTION_CLOSED'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'returns opaque unforgeable capabilities and hides native mutation helpers' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $txProperties = @($tx.PSObject.Properties.Name)
        Assert-CcodEqual 'RootDirectory' ($txProperties -join ',') 'transaction reveals only its root capability'
        $rootProperties = @($tx.RootDirectory.PSObject.Properties.Name)
        Assert-CcodEqual '' ($rootProperties -join ',') 'directory capability reveals no native or ownership state'
        $transactionAssemblyExports = @([CcodInstallCapabilityMarker].Assembly.ExportedTypes | Select-Object -ExpandProperty Name | Sort-Object)
        Assert-CcodEqual 'CcodInstallCapabilityMarker' ($transactionAssemblyExports -join ',') 'transaction assembly exports only a non-mutating marker type'
        $dangerousPublicMethods = @([CcodInstallCapabilityMarker].Assembly.ExportedTypes | ForEach-Object {
            $_.GetMethods([Reflection.BindingFlags]'Public,Static') | Where-Object {
                $_.Name -match 'Open|Create|Rename|Delete|Write|Append|Promote|Remove' -or
                @($_.GetParameters().ParameterType.FullName) -contains 'Microsoft.Win32.SafeHandles.SafeFileHandle'
            }
        })
        Assert-CcodEqual 0 $dangerousPublicMethods.Count 'transaction assembly exposes no public native mutation helper'
        Assert-CcodEqual $null ('CcodInstallRuntime' -as [type]) 'internal runtime type is not directly callable through PowerShell type resolution'

        $forged = [pscustomobject]@{}
        Assert-CcodThrows {
            Open-CcodInstallPinnedDirectory -Transaction $forged -ParentDirectory $tx.RootDirectory -Leaf 'forged' -CreateIfMissing | Out-Null
        } 'CCOD_INSTALL_TRANSACTION_INVALID'

        $otherFixture = New-CcodInstallFileFixture
        try {
            $other = Open-CcodFixtureTransaction $otherFixture
            Assert-CcodThrows {
                Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $other.RootDirectory -Leaf 'cross-issuer' -CreateIfMissing | Out-Null
            } 'CCOD_INSTALL_PIN_INVALID'
        } finally { Remove-CcodInstallFileFixture $otherFixture }
        Assert-CcodOutsideUnchanged $fixture 'opaque capability rejection'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'recomputes the private seal and never trusts forged public fields' {
    $fixture = New-CcodInstallFileFixture
    try {
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $temporary = New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'sealed.tmp'
        Copy-CcodInstallSealedFile -Transaction $tx -SourcePath $source.Path -DestinationLeaf $temporary -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256 | Out-Null
        $forgedLeaf = [pscustomobject]@{ Sealed = $true; Length = $source.Length; Sha256 = $source.Sha256 }
        Assert-CcodThrows {
            Commit-CcodInstallPinnedPromotion -Transaction $tx -ParentDirectory $tx.RootDirectory -TemporaryLeaf $forgedLeaf -DestinationLeaf 'forged.bin' | Out-Null
        } 'CCOD_INSTALL_PIN_INVALID'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $fixture.Install 'forged.bin'))) 'forged public sealing fields cannot create a destination'
        $independentWrite = $null
        try {
            $independentWrite = [IO.File]::Open((Join-Path $fixture.Install 'sealed.tmp'), [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        } catch [IO.IOException] { }
        if ($null -ne $independentWrite) {
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes('tampered')
                $independentWrite.SetLength(0); $independentWrite.Write($bytes,0,$bytes.Length); $independentWrite.Flush($true)
            } finally { $independentWrite.Dispose() }
            Assert-CcodThrows {
                Commit-CcodInstallPinnedPromotion -Transaction $tx -ParentDirectory $tx.RootDirectory -TemporaryLeaf $temporary -DestinationLeaf 'sealed.bin' | Out-Null
            } 'CCOD_INSTALL_SEAL_MISMATCH'
        } else {
            Commit-CcodInstallPinnedPromotion -Transaction $tx -ParentDirectory $tx.RootDirectory -TemporaryLeaf $temporary -DestinationLeaf 'sealed.bin' | Out-Null
            Close-CcodInstallFileTransaction -Transaction $tx -Disposition Ready | Out-Null
            $fixture.Transaction = $null
            Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 (Join-Path $fixture.Install 'sealed.bin')) 'blocked mutation preserves sealed promotion bytes'
        }
        Assert-CcodOutsideUnchanged $fixture 'seal recomputation'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'promotion is no-replace when a destination appears before commit' {
    $fixture = New-CcodInstallFileFixture
    try {
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $temporary = New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'new.tmp'
        Copy-CcodInstallSealedFile -Transaction $tx -SourcePath $source.Path -DestinationLeaf $temporary -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256 | Out-Null
        $destination = Join-Path $fixture.Install 'existing.bin'
        [IO.File]::WriteAllText($destination, 'unexpected-existing-object')
        $existingSha = Get-CcodTestFileSha256 $destination
        Assert-CcodThrows {
            Commit-CcodInstallPinnedPromotion -Transaction $tx -ParentDirectory $tx.RootDirectory -TemporaryLeaf $temporary -DestinationLeaf 'existing.bin' | Out-Null
        } 'CCOD_INSTALL_PROMOTION_DESTINATION_EXISTS'
        Assert-CcodEqual $existingSha (Get-CcodTestFileSha256 $destination) 'no-replace leaves the existing object untouched'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $fixture.Install 'new.tmp'))) 'no-replace failure retains the sealed temporary leaf'
        Assert-CcodOutsideUnchanged $fixture 'no-replace promotion'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

foreach ($directoryCase in @('root','child','owned')) {
    Invoke-CcodTest "rejects $directoryCase directory alternate data streams" {
        $fixture = New-CcodInstallFileFixture
        try {
            if ($directoryCase -ceq 'root') {
                $adsPath = $fixture.Install + ':metadata'
                $adsResult = Invoke-CcodAttemptAdsWrite $adsPath
                Assert-CcodEqual 'created' $adsResult.Outcome 'root ADS fixture is established before pinning'
                Assert-CcodThrows { Open-CcodFixtureTransaction $fixture | Out-Null } 'CCOD_INSTALL_ADS_LEAF'
            } else {
                $tx = Open-CcodFixtureTransaction $fixture
                $directory = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf $directoryCase -CreateIfMissing
                $adsPath = (Join-Path $fixture.Install $directoryCase) + ':metadata'
                $adsResult = Invoke-CcodAttemptAdsWrite $adsPath
                if ($adsResult.Outcome -ceq 'blocked') {
                    Assert-CcodTrue $true "$directoryCase directory pin blocks ADS creation"
                } elseif ($directoryCase -ceq 'child') {
                    Assert-CcodThrows {
                        New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $directory -Leaf 'blocked.tmp' | Out-Null
                    } 'CCOD_INSTALL_ADS_LEAF'
                } else {
                    Assert-CcodThrows {
                        Remove-CcodInstallOwnedTree -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'owned'
                    } 'CCOD_INSTALL_ADS_LEAF'
                    Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install 'owned'))) 'directory ADS cleanup failure retains the owned directory'
                }
            }
            Assert-CcodOutsideUnchanged $fixture "$directoryCase directory ADS"
        } finally { Remove-CcodInstallFileFixture $fixture }
    }
}

Invoke-CcodTest 'rolls back earlier delete dispositions when a later owned leaf cannot be deleted' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate' -CreateIfMissing
        $first = New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $candidate -Leaf 'a.tmp'
        $later = New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $candidate -Leaf 'z.tmp'
        [IO.File]::SetAttributes((Join-Path $fixture.Install 'candidate\z.tmp'), [IO.FileAttributes]::ReadOnly)
        Assert-CcodThrows {
            Remove-CcodInstallOwnedTree -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate'
        } 'CCOD_INSTALL_DELETE_FAILED'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $fixture.Install 'candidate\a.tmp'))) 'later deletion failure restores the first leaf disposition'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $fixture.Install 'candidate\z.tmp'))) 'later deletion failure retains the blocked leaf'
        Assert-CcodOutsideUnchanged $fixture 'all-or-nothing delete rollback'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'clears a child-directory disposition when the later root mark fails' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate' -CreateIfMissing
        $child = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $candidate -Leaf 'child' -CreateIfMissing
        Assert-CcodThrows {
            Remove-CcodInstallOwnedTree -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate'
        } 'CCOD_INSTALL_DELETE_FAILED'
        Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install 'candidate')) ) 'later root-mark failure retains the candidate root'
        Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install 'candidate\child')) ) 'later root-mark failure clears the child-directory disposition'
        Assert-CcodOutsideUnchanged $fixture 'directory disposition rollback'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'detects an unknown insertion between deletion planning and first release' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate' -CreateIfMissing
        $first = New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $candidate -Leaf 'a-first.tmp'
        for ($index = 0; $index -lt 128; $index++) {
            New-CcodInstallPinnedTemporaryLeaf -Transaction $tx -ParentDirectory $candidate -Leaf ('b-{0:d3}.tmp' -f $index) | Out-Null
        }
        $watch = Join-Path $fixture.Install 'candidate\a-first.tmp'
        $unknown = Join-Path $fixture.Install 'candidate\concurrent-unknown.tmp'
        $attacker = [CcodInstallTransactionTestNative]::InsertUnknownAfterDelay($unknown, 1)
        $failure = $null
        try { Remove-CcodInstallOwnedTree -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate' }
        catch { $failure = $_ }
        $attackOutcome = $attacker.GetAwaiter().GetResult()
        Assert-CcodTrue ($attackOutcome -in @('inserted','blocked')) 'concurrent namespace attempt reaches the cleanup boundary'
        if ($attackOutcome -ceq 'inserted') {
            Assert-CcodTrue ($null -ne $failure -and $failure.FullyQualifiedErrorId -match '^CCOD_INSTALL_(?:UNKNOWN_LEAF|DELETE_FAILED)') "inserted unknown leaf fails cleanup before release actual=$($failure.FullyQualifiedErrorId) message=$($failure.Exception.Message)"
            Assert-CcodTrue ([IO.File]::Exists($watch)) 'failed concurrent cleanup retains the first candidate leaf'
            Assert-CcodTrue ([IO.File]::Exists($unknown)) 'unproven concurrent object is retained for diagnosis'
            Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install 'candidate'))) 'concurrent insertion retains the complete candidate tree'
        } else {
            Assert-CcodTrue ($null -ne $failure -and $failure.FullyQualifiedErrorId -like 'CCOD_INSTALL_DELETE_FAILED*') 'blocked insertion still fails closed when the nonempty root disposition is unsupported'
        }
        Assert-CcodOutsideUnchanged $fixture 'concurrent cleanup insertion'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'owned directory denies external child creation and hard-link insertion for its lifetime' {
    $fixture = New-CcodInstallFileFixture
    try {
        $outsideSource = Join-Path $fixture.Outside 'outside-source.bin'
        [IO.File]::WriteAllText($outsideSource, 'outside-source')
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'candidate' -CreateIfMissing
        $childPath = Join-Path $fixture.Install 'candidate\attacker-child.bin'
        $writeHandleError = [CcodInstallTransactionTestNative]::TryOpenDirectoryForChildWrite((Join-Path $fixture.Install 'candidate'))
        Assert-CcodTrue ($writeHandleError -ne 0) 'owned directory share lock blocks an external child-write handle'

        $hardLinkPath = Join-Path $fixture.Install 'candidate\attacker-hardlink.bin'
        $hardLinkError = [CcodInstallTransactionTestNative]::CreateHardLink($hardLinkPath, $outsideSource)
        Assert-CcodTrue ($hardLinkError -ne 0) 'owned directory share lock blocks external hard-link insertion'
        Assert-CcodTrue (-not [IO.File]::Exists($childPath)) 'blocked child path remains absent'
        Assert-CcodTrue (-not [IO.File]::Exists($hardLinkPath)) 'blocked hard-link path remains absent'
        Assert-CcodOutsideUnchanged $fixture 'owned directory namespace lock'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'closing releases every sharing lock and rejects close-versus-relative operations' {
    $fixture = New-CcodInstallFileFixture
    try {
        $tx = Open-CcodFixtureTransaction $fixture
        $child = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $tx.RootDirectory -Leaf 'release-me' -CreateIfMissing
        Close-CcodInstallFileTransaction -Transaction $tx -Disposition Failed | Out-Null
        $fixture.Transaction = $null
        Assert-CcodThrows {
            Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $child -Leaf 'after-close' -CreateIfMissing | Out-Null
        } 'CCOD_INSTALL_TRANSACTION_CLOSED'
        $renamed = Join-Path $fixture.Install 'released'
        [IO.Directory]::Move((Join-Path $fixture.Install 'release-me'), $renamed)
        [IO.Directory]::Delete($renamed)
        Assert-CcodTrue (-not [IO.Directory]::Exists($renamed)) 'closed transaction releases directory sharing locks'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Write-Host 'Install file transaction self-test passed.' -ForegroundColor Green
