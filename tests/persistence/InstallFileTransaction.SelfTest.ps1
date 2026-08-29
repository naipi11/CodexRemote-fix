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
using System.Runtime.InteropServices;
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

    public static SafeFileHandle OpenFileAllowDeleteShare(string path)
    {
        SafeFileHandle handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
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
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$DirectoryPin
    )
    $renamedLeaf = $DirectoryPin.Leaf + '.attacker-old'
    # The production pin intentionally denies delete sharing. Reopen only inside
    # this fault-injection helper so the independent final-path guard is tested.
    $descendantPrefix = [IO.Path]::GetFullPath($DirectoryPin.ExpectedPath).TrimEnd('\') + '\'
    $descendants = @($Transaction.Pins | Where-Object {
        -not $_.Closed -and $_.Kind -ceq 'File' -and
        [IO.Path]::GetFullPath([string]$_.ExpectedPath).StartsWith($descendantPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($pin in $descendants) { $pin.Stream.Dispose() }
    $DirectoryPin.Handle.Dispose()
    $DirectoryPin.Handle = [CcodInstallTransactionTestNative]::OpenDirectoryAllowDeleteShare($DirectoryPin.ExpectedPath)
    $moved = Join-Path $DirectoryPin.ParentDirectory.ExpectedPath $renamedLeaf
    $renameError = Invoke-CcodInstallModule {
        param($Pin,$RenamedLeaf)
        [CcodInstallFileNative]::RenameRelative($Pin.Handle, $Pin.ParentDirectory.Handle, $RenamedLeaf, $false)
    } @($DirectoryPin,$renamedLeaf)
    if ($renameError -ne 0) { throw "Could not rename fault-injection directory: Windows error $renameError" }
    foreach ($pin in $descendants) {
        $relative = [IO.Path]::GetFullPath([string]$pin.ExpectedPath).Substring($descendantPrefix.Length)
        $fileHandle = [CcodInstallTransactionTestNative]::OpenFileAllowDeleteShare((Join-Path $moved $relative))
        $pin.Stream = [IO.FileStream]::new($fileHandle, [IO.FileAccess]::ReadWrite, 65536, $false)
    }
    $result = & cmd.exe /d /c mklink /J $DirectoryPin.ExpectedPath $Fixture.Outside 2>&1
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
        $hook = {
            param($OpenedSource)
            try {
                [IO.File]::Move($OpenedSource, ($OpenedSource + '.attacker-old'))
                return [pscustomobject]@{ Outcome = 'replaced' }
            } catch [IO.IOException] {
                return [pscustomobject]@{ Outcome = 'blocked' }
            } catch [UnauthorizedAccessException] {
                return [pscustomobject]@{ Outcome = 'blocked' }
            }
        }
        Invoke-CcodInstallModule { param($Hook) $script:CcodInstallFileTransactionAfterSourceOpen = $Hook } @($hook) | Out-Null
        try {
            $copy = Invoke-CcodInstallModule {
                param($Tx,$Source,$Leaf,$Length,$Sha)
                Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha
            } @($tx,$source.Path,$temporary,$source.Length,$source.Sha256)
        } finally {
            Invoke-CcodInstallModule { $script:CcodInstallFileTransactionAfterSourceOpen = $null } | Out-Null
        }
        Assert-CcodEqual 'blocked' $tx.LastSourceOpenAttempt.Outcome 'source replacement is blocked after its read handle opens'
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

Invoke-CcodTest 'rejects an ADS-bearing promotion destination and retains the temporary leaf' {
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
        } 'CCOD_INSTALL_ADS_LEAF'
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
        $attack = Invoke-CcodReplacePinnedDirectory -Fixture $fixture -Transaction $tx -DirectoryPin $runtime
        Assert-CcodEqual 'replaced' $attack.Outcome 'fixture ancestor replacement is established'
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx,$Parent,$Leaf) Commit-CcodInstallPinnedPromotion -Transaction $Tx -ParentDirectory $Parent -TemporaryLeaf $Leaf -DestinationLeaf 'payload.bin' } @($tx,$runtime,$temporary) | Out-Null
        } 'CCOD_INSTALL_PIN_CHANGED'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $attack.MovedDirectory 'payload.tmp'))) 'renamed-parent promotion retains its temporary candidate'
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

Invoke-CcodTest 'deletes a fully proven transaction-owned tree from leaves upward' {
    $fixture = New-CcodInstallFileFixture
    try {
        $source = New-CcodSourceFile $fixture
        $tx = Open-CcodFixtureTransaction $fixture
        $candidate = Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'candidate' -CreateIfMissing } @($tx)
        $temporary = Invoke-CcodInstallModule { param($Tx,$Parent) New-CcodInstallPinnedTemporaryLeaf -Transaction $Tx -ParentDirectory $Parent -Leaf 'payload.tmp' } @($tx,$candidate)
        Invoke-CcodInstallModule {
            param($Tx,$Source,$Leaf,$Length,$Sha)
            Copy-CcodInstallSealedFile -Transaction $Tx -SourcePath $Source -DestinationLeaf $Leaf -ExpectedLength $Length -ExpectedSha256 $Sha | Out-Null
            Commit-CcodInstallPinnedPromotion -Transaction $Tx -ParentDirectory $Leaf.ParentDirectory -TemporaryLeaf $Leaf -DestinationLeaf 'payload.bin' | Out-Null
        } @($tx,$source.Path,$temporary,$source.Length,$source.Sha256)
        Invoke-CcodInstallModule { param($Tx) Remove-CcodInstallOwnedTree -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'candidate' } @($tx) | Out-Null
        Assert-CcodTrue (-not [IO.Directory]::Exists((Join-Path $fixture.Install 'candidate'))) 'proven owned tree is removed'
        Assert-CcodOutsideUnchanged $fixture 'owned tree removal'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

foreach ($case in @('json','log')) {
    Invoke-CcodTest "rejects a pinned $case write after parent pathname replacement" {
        $fixture = New-CcodInstallFileFixture
        try {
            $tx = Open-CcodFixtureTransaction $fixture
            $parent = Invoke-CcodInstallModule { param($Tx,$Leaf) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf $Leaf -CreateIfMissing } @($tx,$case)
            $attack = Invoke-CcodReplacePinnedDirectory -Fixture $fixture -Transaction $tx -DirectoryPin $parent
            Assert-CcodEqual 'replaced' $attack.Outcome "$case fixture replacement is established"
            if ($case -ceq 'json') {
                Assert-CcodThrows {
                    Invoke-CcodInstallModule { param($Tx,$Parent) Write-CcodInstallPinnedJson -Transaction $Tx -ParentDirectory $Parent -Leaf 'state.json' -Value ([ordered]@{ schemaVersion = 1; value = 'safe' }) -Compress } @($tx,$parent)
                } 'CCOD_INSTALL_PIN_CHANGED'
                Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $fixture.Outside 'state.json'))) 'replaced JSON path is untouched'
            } else {
                Assert-CcodThrows {
                    Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'safe'; code = 'CCOD_TEST' }) } @($tx,$parent)
                } 'CCOD_INSTALL_PIN_CHANGED'
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
        Invoke-CcodInstallModule { param($Tx,$Parent) Write-CcodInstallPinnedJson -Transaction $Tx -ParentDirectory $Parent -Leaf 'active.json' -Value ([ordered]@{ schemaVersion = 1; active = 'runtime-b' }) -Compress } @($tx,$state) | Out-Null
        Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'one'; code = 'CCOD_OK' }) } @($tx,$logs) | Out-Null
        Invoke-CcodInstallModule { param($Tx,$Parent) Append-CcodInstallPinnedLog -Transaction $Tx -ParentDirectory $Parent -Leaf 'install.log' -Record ([ordered]@{ event = 'two'; code = 'CCOD_READY' }) } @($tx,$logs) | Out-Null
        Invoke-CcodInstallModule { param($Tx) Close-CcodInstallFileTransaction -Transaction $Tx -Disposition Ready } @($tx) | Out-Null
        $fixture.Transaction = $null

        $json = [IO.File]::ReadAllText((Join-Path $fixture.Install 'state\active.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        Assert-CcodEqual 'runtime-b' $json.active 'second pinned JSON write atomically replaces the first'
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
        Assert-CcodEqual 'Ready' $tx.Disposition 'close records the terminal disposition'
        Assert-CcodTrue $tx.Closed 'close marks the context closed'
        Assert-CcodThrows {
            Invoke-CcodInstallModule { param($Tx) Open-CcodInstallPinnedDirectory -Transaction $Tx -ParentDirectory $Tx.RootDirectory -Leaf 'after-close' -CreateIfMissing } @($tx) | Out-Null
        } 'CCOD_INSTALL_TRANSACTION_CLOSED'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Write-Host 'Install file transaction self-test passed.' -ForegroundColor Green
