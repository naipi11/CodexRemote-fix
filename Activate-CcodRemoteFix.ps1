[CmdletBinding()]
param(
    [string]$AppRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$PayloadRoot,
    [string]$PackagePath,
    [string]$PackageManifestPath,
    [string]$ExpectedPackageSha256,
    [string]$ExpectedPackageManifestSha256,
    [string]$ExpectedGitCommit,
    [string]$ExpectedVersion,
    [string]$ExpectedPayloadManifestSha256,
    [string]$ActivationId,
    [switch]$ValidateReceiptOnly,
    [switch]$ValidateReceiptWithTimeout,
    [ValidateRange(1,300000)][int]$ValidationTimeoutMilliseconds = 2000,
    [ValidateRange(1,300000)][int]$FirstReceiptTimeoutMilliseconds = 90000,
    [ValidateRange(1,300000)][int]$ActivationTimeoutMilliseconds = 300000,
    [switch]$Prompt,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
$script:CcodActivationReceiptFields = @('schemaVersion','activationId','phase','runtimeId','previousRuntimeId','startedAtUtc','updatedAtUtc','ready','errorCode')
$script:CcodActivationReceiptPhases = @('StoppingPreviousRuntime','InstallingRuntime','ActivatingRuntime','StartingProtection','Ready','Failed')
$script:CcodActivationReceiptMaximumBytes = 16384

function Test-CcodCanonicalGuid {
    param($Value)
    $parsed = [guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodCanonicalUtc {
    param($Value)
    $parsed = [DateTime]::MinValue
    return $Value -is [string] -and
        [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Write-CcodActivationRecord {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][long]$DurationMilliseconds)
    try {
        $directory = Join-Path $InstallRoot 'logs'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $record = [ordered]@{
            schemaVersion = 1
            timestampUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            component = 'PostInstallActivation'
            activationId = $ActivationId
            submissionId = $null
            transactionId = $null
            code = $Code
            durationMilliseconds = [long][Math]::Max(0,$DurationMilliseconds)
        }
        [IO.File]::AppendAllText((Join-Path $directory 'post-install-activation.log'),(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
    } catch { }
}

function Get-CcodActivationFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream=$null;$sha=[Security.Cryptography.SHA256]::Create()
    try{$stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}
    finally{if($null-ne$stream){$stream.Dispose()};$sha.Dispose()}
}

function Test-CcodActivationPackageRelativePath {
    param($Path)
    return $Path-is[string]-and$Path-cmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-and-not$Path.Contains('//')-and-not$Path.Contains('..')-and-not$Path.Contains(':')-and-not$Path.Contains('\')-and-not$Path.EndsWith('/')
}

function Open-CcodInstallerPackageSeal {
    param([Parameter(Mandatory)][string]$PackagePath,[Parameter(Mandatory)][string]$PackageManifestPath,[Parameter(Mandatory)][string]$ExpectedPackageSha256,[Parameter(Mandatory)][string]$ExpectedPackageManifestSha256,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    if($ExpectedPackageSha256-cnotmatch'^[0-9a-f]{64}$'-or$ExpectedPackageManifestSha256-cnotmatch'^[0-9a-f]{64}$'-or$ExpectedVersion-cnotmatch'^\d+\.\d+\.\d+$'-or$ExpectedGitCommit-cnotmatch'^[0-9a-f]{40}$'){throw 'CCOD_INSTALLER_PACKAGE_INVALID'}
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $package=[IO.Path]::GetFullPath($PackagePath);$manifestPath=[IO.Path]::GetFullPath($PackageManifestPath);$packageStream=$null;$manifestStream=$null;$archive=$null
    try{
        foreach($path in @($package,$manifestPath)){$item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0-or$item.Length-le 0-or$item.Length-gt 536870912){throw 'CCOD_INSTALLER_PACKAGE_INVALID'}}
        $packageStream=[IO.File]::Open($package,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$sha=[Security.Cryptography.SHA256]::Create();try{$actualPackage=[BitConverter]::ToString($sha.ComputeHash($packageStream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};$packageStream.Position=0;if($actualPackage-cne$ExpectedPackageSha256){throw 'CCOD_INSTALLER_PACKAGE_HASH_MISMATCH'}
        $manifestStream=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$sha=[Security.Cryptography.SHA256]::Create();try{$actualManifest=[BitConverter]::ToString($sha.ComputeHash($manifestStream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};$manifestStream.Position=0;if($actualManifest-cne$ExpectedPackageManifestSha256){throw 'CCOD_INSTALLER_PACKAGE_MANIFEST_HASH_MISMATCH'}
        $reader=[IO.StreamReader]::new($manifestStream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};$manifestStream.Position=0;try{$manifest=$text|ConvertFrom-Json -ErrorAction Stop}catch{throw 'CCOD_INSTALLER_PACKAGE_INVALID'}
        if($manifest-isnot[pscustomobject]-or(@($manifest.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,payloadManifest,files'-or$manifest.schemaVersion-isnot[int]-or$manifest.schemaVersion-ne 1-or$manifest.product-cne'CodexRemote-fix'-or$manifest.version-cne$ExpectedVersion-or$manifest.gitCommit-cne$ExpectedGitCommit-or$manifest.payloadManifest.name-cne'installer-payload.manifest.json'-or$manifest.payloadManifest.sha256-cnotmatch'^[0-9a-f]{64}$'){throw 'CCOD_INSTALLER_PACKAGE_INVALID'}
        $records=@($manifest.files);if($records.Count-eq 0){throw 'CCOD_INSTALLER_PACKAGE_INVALID'};$expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);$previous=$null
        foreach($record in $records){if($record-isnot[pscustomobject]-or(@($record.PSObject.Properties.Name)-join',')-cne'path,length,sha256'-or-not(Test-CcodActivationPackageRelativePath $record.path)-or$record.length-isnot[ValueType]-or[decimal]$record.length-ne[decimal][int64]$record.length-or[int64]$record.length-lt 0-or$record.sha256-cnotmatch'^[0-9a-f]{64}$'-or($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,[string]$record.path)-ge 0)-or$expected.ContainsKey([string]$record.path)){throw 'CCOD_INSTALLER_PACKAGE_INVALID'};$expected.Add([string]$record.path,$record);$previous=[string]$record.path}
        $archive=[IO.Compression.ZipArchive]::new($packageStream,[IO.Compression.ZipArchiveMode]::Read,$true);$entries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in @($archive.Entries)){if(-not(Test-CcodActivationPackageRelativePath $entry.FullName)-or$entries.ContainsKey($entry.FullName)-or$entry.Name.Length-eq 0){throw 'CCOD_INSTALLER_PACKAGE_INVALID'};$entries.Add($entry.FullName,$entry)}
        if($entries.Count-ne$expected.Count+1-or-not$entries.ContainsKey('installer-payload.manifest.json')){throw 'CCOD_INSTALLER_PACKAGE_INVALID'}
        foreach($pair in $expected.GetEnumerator()){$entry=$entries[$pair.Key];$record=$pair.Value;if([int64]$entry.Length-ne[int64]$record.length){throw 'CCOD_INSTALLER_PACKAGE_INVALID'};$stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()};if($hash-cne[string]$record.sha256){throw 'CCOD_INSTALLER_PACKAGE_INVALID'}}
        $payloadEntry=$entries['installer-payload.manifest.json'];$stream=$payloadEntry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$payloadHash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()};if([int64]$payloadEntry.Length-ne[int64]$manifest.payloadManifest.length-or$payloadHash-cne[string]$manifest.payloadManifest.sha256){throw 'CCOD_INSTALLER_PACKAGE_INVALID'}
        return [pscustomobject]@{PackageStream=$packageStream;ManifestStream=$manifestStream;Archive=$archive;Manifest=$manifest;Entries=$entries;PayloadManifestSha256=$payloadHash}
    }catch{if($null-ne$archive){$archive.Dispose()};if($null-ne$manifestStream){$manifestStream.Dispose()};if($null-ne$packageStream){$packageStream.Dispose()};throw}
}

function Expand-CcodInstallerPackageSeal {
    param([Parameter(Mandatory)]$Seal,[Parameter(Mandatory)][string]$DestinationRoot)
    $root=[IO.Path]::GetFullPath($DestinationRoot);if([IO.File]::Exists($root)-or[IO.Directory]::Exists($root)){throw 'CCOD_INSTALLER_PACKAGE_INVALID'};[IO.Directory]::CreateDirectory($root)|Out-Null
    try{foreach($entry in @($Seal.Archive.Entries)){$target=[IO.Path]::GetFullPath((Join-Path $root $entry.FullName.Replace('/','\')));if(-not$target.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'CCOD_INSTALLER_PACKAGE_INVALID'};$parent=Split-Path $target -Parent;if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};$source=$entry.Open();$destination=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$source.CopyTo($destination);$destination.Flush($true)}finally{$destination.Dispose();$source.Dispose()}};return $root}catch{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue};throw}
}

function Close-CcodInstallerPackageSeal { param($Seal) if($null-eq$Seal){return};foreach($name in @('Archive','ManifestStream','PackageStream')){try{if($null-ne$Seal.$name){$Seal.$name.Dispose()}}catch{}} }

function Get-CcodActivationBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Open-CcodActivationLockedBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,268435456)][int64]$MaximumBytes = 268435456
    )

    $full = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 0 -or $stream.Length -gt $MaximumBytes) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally { $memory.Dispose() }
        return [pscustomobject]@{ Path=$full; Stream=$stream; Bytes=$bytes }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Initialize-CcodActivationStageNative {
    if ($null -ne ('CcodActivationStageNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CcodActivationStageNative
{
    private const uint FILE_READ_DATA = 0x00000001;
    private const uint FILE_LIST_DIRECTORY = 0x00000001;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_OPEN = 0x00000001;
    private const uint FILE_CREATE = 0x00000002;
    private const uint FILE_DIRECTORY_FILE = 0x00000001;
    private const uint FILE_NON_DIRECTORY_FILE = 0x00000040;
    private const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
    private const uint FILE_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint OPEN_EXISTING = 3;
    private const uint OBJ_CASE_INSENSITIVE = 0x00000040;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;

    [StructLayout(LayoutKind.Sequential)]
    private struct UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public UIntPtr Information;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("ntdll.dll")]
    private static extern int NtCreateFile(out IntPtr fileHandle, uint desiredAccess,
        ref OBJECT_ATTRIBUTES objectAttributes, out IO_STATUS_BLOCK ioStatusBlock, IntPtr allocationSize,
        uint fileAttributes, uint shareAccess, uint createDisposition, uint createOptions,
        IntPtr eaBuffer, uint eaLength);

    private static void ValidateLeaf(string name)
    {
        if (String.IsNullOrWhiteSpace(name) || name == "." || name == ".." || name.IndexOf('\\') >= 0 || name.IndexOf('/') >= 0)
            throw new ArgumentException("Relative stage leaf is invalid", "name");
    }

    private static SafeFileHandle OpenRelative(SafeFileHandle parent, string name, uint access, uint share,
        uint disposition, uint options)
    {
        ValidateLeaf(name);
        if (parent == null || parent.IsInvalid || parent.IsClosed) throw new ArgumentException("Parent directory pin is invalid", "parent");
        IntPtr nameBuffer = IntPtr.Zero;
        IntPtr unicodePointer = IntPtr.Zero;
        try
        {
            nameBuffer = Marshal.StringToHGlobalUni(name);
            UNICODE_STRING unicode = new UNICODE_STRING();
            unicode.Length = checked((ushort)(name.Length * 2));
            unicode.MaximumLength = checked((ushort)((name.Length + 1) * 2));
            unicode.Buffer = nameBuffer;
            unicodePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
            Marshal.StructureToPtr(unicode, unicodePointer, false);
            OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES();
            attributes.Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));
            attributes.RootDirectory = parent.DangerousGetHandle();
            attributes.ObjectName = unicodePointer;
            attributes.Attributes = OBJ_CASE_INSENSITIVE;
            IO_STATUS_BLOCK statusBlock;
            IntPtr rawHandle;
            int status = NtCreateFile(out rawHandle, access, ref attributes, out statusBlock, IntPtr.Zero,
                0, share, disposition, options | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
                IntPtr.Zero, 0);
            if (status < 0 || rawHandle == IntPtr.Zero || rawHandle == new IntPtr(-1))
                throw new InvalidOperationException("NtCreateFile failed: 0x" + unchecked((uint)status).ToString("x8"));
            return new SafeFileHandle(rawHandle, true);
        }
        finally
        {
            if (unicodePointer != IntPtr.Zero) Marshal.FreeHGlobal(unicodePointer);
            if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
        }
    }

    public static SafeFileHandle OpenExistingDirectory(string path)
    {
        SafeFileHandle handle = CreateFileW(path, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information) ||
            (information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error != 0) throw new Win32Exception(error);
            throw new InvalidOperationException("Existing stage parent is not a plain directory");
        }
        return handle;
    }

    public static SafeFileHandle CreateDirectoryRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_CREATE, FILE_DIRECTORY_FILE);
    }

    public static SafeFileHandle CreateLeafRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, GENERIC_WRITE | SYNCHRONIZE,
            FILE_SHARE_READ, FILE_CREATE, FILE_NON_DIRECTORY_FILE);
    }

    public static SafeFileHandle OpenLeafIdentityRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_OPEN, FILE_NON_DIRECTORY_FILE);
    }

    public static SafeFileHandle OpenLeafReadRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, GENERIC_READ | SYNCHRONIZE,
            FILE_SHARE_READ, FILE_OPEN, FILE_NON_DIRECTORY_FILE);
    }
}
'@
}

function Get-CcodActivationPinnedDirectory {
    param(
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string,object]]$Directories,
        [Parameter(Mandatory)][Collections.Generic.List[object]]$DirectoryPins,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativeDirectory
    )
    $normalized = $RelativeDirectory.Replace('/','\').Trim('\')
    if ([string]::IsNullOrEmpty($normalized)) { return $Directories[''] }
    $current = ''
    $parent = $Directories['']
    foreach ($segment in ($normalized -split '\\')) {
        if ($segment -notmatch '^[A-Za-z0-9._-]+$' -or $segment -in @('.','..')) { throw 'CCOD_INSTALL_PAYLOAD_PATH_INVALID' }
        $current = if ([string]::IsNullOrEmpty($current)) { $segment } else { "$current\$segment" }
        if ($Directories.ContainsKey($current)) { $parent = $Directories[$current]; continue }
        $created = [CcodActivationStageNative]::CreateDirectoryRelative($parent,[string]$segment)
        $DirectoryPins.Add($created)
        $Directories.Add($current,$created)
        $parent = $created
    }
    return $parent
}

function Open-CcodActivationPinnedLeafBytes {
    param(
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $writerHandle = $null
    $identityHandle = $null
    $writer = $null
    try {
        $writerHandle = [CcodActivationStageNative]::CreateLeafRelative($ParentDirectory,$Leaf)
        $writer = [IO.FileStream]::new($writerHandle,[IO.FileAccess]::Write,65536,$false)
        $writerHandle = $null
        $writer.Write($Bytes,0,$Bytes.Length)
        $writer.Flush($true)
        $identityHandle = [CcodActivationStageNative]::OpenLeafIdentityRelative($ParentDirectory,$Leaf)
        $writer.Dispose(); $writer = $null
        $readHandle = [CcodActivationStageNative]::OpenLeafReadRelative($ParentDirectory,$Leaf)
        $stream = [IO.FileStream]::new($readHandle,[IO.FileAccess]::Read,65536,$false)
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $readBytes = $memory.ToArray() }
        finally { $memory.Dispose() }
        $identityHandle.Dispose(); $identityHandle = $null
        return [pscustomobject]@{ Stream=$stream; Bytes=$readBytes }
    } catch {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $writerHandle) { $writerHandle.Dispose() }
        if ($null -ne $identityHandle) { $identityHandle.Dispose() }
        throw
    }
}

function Assert-CcodActivationNonReparsePath {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $prefix = $canonicalRoot + '\'
    if (-not ($canonicalPath.Equals($canonicalRoot,[StringComparison]::OrdinalIgnoreCase) -or $canonicalPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'CCOD_INSTALL_PAYLOAD_PATH_INVALID'
    }
    $cursor = $canonicalPath
    while ($true) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CCOD_INSTALL_SOURCE_REPARSE' }
        if ($cursor.Equals($canonicalRoot,[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path $cursor -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw 'CCOD_INSTALL_PAYLOAD_PATH_INVALID' }
        $cursor = $parent
    }
    return $canonicalPath
}

function Test-CcodActivationAlternateDataStreams {
    param([Parameter(Mandatory)][string]$Path)
    try {
        foreach ($stream in @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)) {
            if ([string]$stream.Stream -cnotin @(':$DATA','::$DATA','$DATA')) { return $true }
        }
        return $false
    } catch {
        throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID'
    }
}

function Remove-CcodActivationPayloadStage {
    param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$StageRoot)
    if (-not [IO.Directory]::Exists($StageRoot)) { return }
    $app = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
    $stage = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    $prefix = $app + '\'
    if (-not $stage.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($stage) -cnotmatch '^\.activation-payload-stage-[0-9a-f]{32}$') { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $stage -Force -Recurse -ErrorAction SilentlyContinue)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    }
    $stageItem = Get-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
    if ($null -eq $stageItem -or ($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

function Close-CcodActivationPayloadSeal {
    param($Seal)
    if ($null -eq $Seal) { return }
    foreach ($stream in @($Seal.Streams)) {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
    }
    $directoryPins = @($Seal.DirectoryPins)
    for ($index=$directoryPins.Count-1;$index-ge0;$index--) {
        if ($null -ne $directoryPins[$index]) { try { $directoryPins[$index].Dispose() } catch { } }
    }
    Remove-CcodActivationPayloadStage -AppRoot $Seal.AppRoot -StageRoot $Seal.StageRoot
}

function New-CcodActivationPayloadSeal {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ExpectedManifestSha256
    )

    if ($Version -cnotmatch '^\d+\.\d+\.\d+$' -or $ExpectedManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH' }
    $app = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
    $payload = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $expectedPayload = [IO.Path]::GetFullPath((Join-Path (Join-Path $app 'payload') $Version)).TrimEnd('\')
    if (-not $payload.Equals($expectedPayload,[StringComparison]::OrdinalIgnoreCase)) { throw 'CCOD_INSTALL_PAYLOAD_PATH_INVALID' }
    [void](Assert-CcodActivationNonReparsePath -Root $app -Path $app)
    [void](Assert-CcodActivationNonReparsePath -Root $app -Path (Join-Path $app 'payload'))
    [void](Assert-CcodActivationNonReparsePath -Root $app -Path $payload)
    $packagePath = Join-Path $payload 'package.json'
    $manifestPath = Join-Path $payload 'installer-payload.manifest.json'
    $modulePath = Join-Path $payload 'src\persistence\modules\InstallLifecycle.psm1'
    if (-not [IO.File]::Exists($packagePath) -or -not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists($modulePath)) {
        throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID'
    }
    [void](Assert-CcodActivationNonReparsePath -Root $payload -Path $manifestPath)
    $sourceLocks = [Collections.Generic.List[object]]::new()
    $stageLocks = [Collections.Generic.List[object]]::new()
    $stageDirectoryPins = [Collections.Generic.List[object]]::new()
    $stageRoot = Join-Path $app ('.activation-payload-stage-' + [guid]::NewGuid().ToString('N'))
    try {
        $manifestLock = Open-CcodActivationLockedBytes -Path $manifestPath -MaximumBytes 4194304
        $sourceLocks.Add($manifestLock)
        $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
        if ($manifestItem.PSIsContainer -or $manifestLock.Bytes.Length -le 0 -or
            (Test-CcodActivationAlternateDataStreams -Path $manifestPath) -or
            (Get-CcodActivationBytesSha256 -Bytes $manifestLock.Bytes) -cne $ExpectedManifestSha256) {
            throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID'
        }
        try {
            $manifestText = [Text.UTF8Encoding]::new($false,$true).GetString($manifestLock.Bytes)
            $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
        } catch { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        $properties = @($manifest.PSObject.Properties.Name)
        $expectedProperties = @('schemaVersion','projectVersion','files')
        if ($manifest -isnot [pscustomobject] -or $properties.Count -ne $expectedProperties.Count) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        for ($index=0;$index-lt$expectedProperties.Count;$index++) {
            if ($properties[$index] -cne $expectedProperties[$index]) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        }
        if ($manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -ne 1 -or $manifest.projectVersion -isnot [string] -or $manifest.projectVersion -cne $Version) {
            throw 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH'
        }
        $records = @($manifest.files)
        if ($records.Count -eq 0) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $snapshots = [Collections.Generic.List[object]]::new()
        $previous = $null
        foreach ($record in $records) {
            $recordProperties = @($record.PSObject.Properties.Name)
            if ($record -isnot [pscustomobject] -or $recordProperties.Count -ne 3 -or $recordProperties[0] -cne 'path' -or $recordProperties[1] -cne 'length' -or $recordProperties[2] -cne 'sha256' -or
                $record.path -isnot [string] -or $record.path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -or $record.path.Contains('//') -or $record.path.Contains('..') -or $record.path.Contains(':') -or $record.path.Contains('\') -or
                $record.length -isnot [ValueType] -or [decimal]$record.length -ne [decimal][int64]$record.length -or [int64]$record.length -lt 0 -or
                $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
            if (($null-ne$previous -and [StringComparer]::Ordinal.Compare([string]$previous,[string]$record.path)-ge 0) -or -not $seen.Add([string]$record.path)) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
            $previous = [string]$record.path
            $source = [IO.Path]::GetFullPath((Join-Path $payload ($record.path.Replace('/','\'))))
            [void](Assert-CcodActivationNonReparsePath -Root $payload -Path $source)
            $locked = Open-CcodActivationLockedBytes -Path $source
            $sourceLocks.Add($locked)
            $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (Test-CcodActivationAlternateDataStreams -Path $source) -or [int64]$locked.Bytes.Length -ne [int64]$record.length -or
                (Get-CcodActivationBytesSha256 -Bytes $locked.Bytes) -cne [string]$record.sha256) { throw 'CCOD_INSTALL_FILE_HASH_MISMATCH' }
            $snapshots.Add([pscustomobject]@{ Relative=[string]$record.path; Bytes=$locked.Bytes; Sha256=[string]$record.sha256 })
        }
        foreach ($required in @('package.json','Install-CodexControlOtherDevices.ps1','src/persistence/modules/InstallLifecycle.psm1','src/persistence/modules/RuntimeManifest.psm1')) {
            if (-not $seen.Contains($required)) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        }
        $actualFileList = [Collections.Generic.List[string]]::new()
        foreach ($actualItem in @(Get-ChildItem -LiteralPath $payload -Force -Recurse -ErrorAction Stop)) {
            if (($actualItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CCOD_INSTALL_SOURCE_REPARSE' }
            if ($actualItem.PSIsContainer -or $actualItem.FullName.Equals($manifestPath,[StringComparison]::OrdinalIgnoreCase)) { continue }
            $actualFileList.Add($actualItem.FullName.Substring($payload.Length + 1).Replace('\','/'))
        }
        $actualFiles = @($actualFileList)
        if ($actualFiles.Count -ne $records.Count) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        foreach ($actual in $actualFiles) { if (-not $seen.Contains([string]$actual)) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' } }
        $packageSnapshot = @($snapshots | Where-Object { $_.Relative -ceq 'package.json' })
        try { $package = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$packageSnapshot[0].Bytes) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        if ($packageSnapshot.Count -ne 1 -or $package.version -isnot [string] -or [string]$package.version -cne $Version) { throw 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH' }

        Initialize-CcodActivationStageNative
        $appPin = [CcodActivationStageNative]::OpenExistingDirectory($app)
        $stageDirectoryPins.Add($appPin)
        $stageName = [IO.Path]::GetFileName($stageRoot)
        $stagePin = [CcodActivationStageNative]::CreateDirectoryRelative($appPin,$stageName)
        $stageDirectoryPins.Add($stagePin)
        $directories = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $directories.Add('',$stagePin)
        [void](Assert-CcodActivationNonReparsePath -Root $app -Path $stageRoot)
        foreach ($snapshot in @($snapshots) + @([pscustomobject]@{Relative='installer-payload.manifest.json';Bytes=$manifestLock.Bytes;Sha256=$ExpectedManifestSha256})) {
            $destination = [IO.Path]::GetFullPath((Join-Path $stageRoot ([string]$snapshot.Relative).Replace('/','\')))
            $stagePrefix = $stageRoot.TrimEnd('\') + '\'
            if (-not $destination.StartsWith($stagePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'CCOD_INSTALL_PAYLOAD_PATH_INVALID' }
            $relativeDirectory = [IO.Path]::GetDirectoryName(([string]$snapshot.Relative).Replace('/','\'))
            $parentPin = Get-CcodActivationPinnedDirectory -Directories $directories -DirectoryPins $stageDirectoryPins -RelativeDirectory $relativeDirectory
            $stageLock = Open-CcodActivationPinnedLeafBytes -ParentDirectory $parentPin -Leaf ([IO.Path]::GetFileName($destination)) -Bytes ([byte[]]$snapshot.Bytes)
            [void](Assert-CcodActivationNonReparsePath -Root $stageRoot -Path $destination)
            $stageLocks.Add($stageLock)
            if ((Get-CcodActivationBytesSha256 -Bytes $stageLock.Bytes) -cne [string]$snapshot.Sha256) { throw 'CCOD_INSTALL_FILE_HASH_MISMATCH' }
        }
        return [pscustomobject]@{
            AppRoot=$app
            StageRoot=[IO.Path]::GetFullPath($stageRoot)
            ManifestPath=Join-Path $stageRoot 'installer-payload.manifest.json'
            ManifestBytes=$manifestLock.Bytes
            Streams=@($stageLocks | ForEach-Object { $_.Stream })
            DirectoryPins=@($stageDirectoryPins)
        }
    } catch {
        foreach ($locked in @($stageLocks)) { try { $locked.Stream.Dispose() } catch { } }
        for ($pinIndex=$stageDirectoryPins.Count-1;$pinIndex-ge0;$pinIndex--) { try { $stageDirectoryPins[$pinIndex].Dispose() } catch { } }
        Remove-CcodActivationPayloadStage -AppRoot $app -StageRoot $stageRoot
        throw
    } finally {
        foreach ($locked in @($sourceLocks)) { try { $locked.Stream.Dispose() } catch { } }
    }
}

function Assert-CcodActivatedRuntimeVersion {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$RuntimeModulePath
    )

    $module = Import-Module $RuntimeModulePath -Force -PassThru
    try {
        $pointer = Read-CcodActiveRuntime -InstallRoot $Root
        if ($pointer.activeRuntime -cne $RuntimeId) { throw 'CCOD_ACTIVATION_RUNTIME_VERSION_MISMATCH' }
        $runtimeRoot = Join-Path (Join-Path $Root 'runtime') $RuntimeId
        $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $RuntimeId
        if (-not $validation.Valid -or [string]$validation.Manifest.projectVersion -cne $Version) {
            throw 'CCOD_ACTIVATION_RUNTIME_VERSION_MISMATCH'
        }
    } finally {
        Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
}

function Assert-CcodActivationReceiptPathSafe {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $prefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    if (-not ($canonicalPath -ceq $canonicalRoot -or $canonicalPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
    }
    $current = $canonicalPath
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
        }
        if ($current -ceq $canonicalRoot) { break }
        $parent = Split-Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) {
            throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
        }
        $current = $parent
    }
}

function Read-CcodTerminalActivationReceipt {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedActivationId)
    $directory = Join-Path $Root 'state\activation-receipts'
    if (-not [IO.Directory]::Exists($directory)) { throw 'CCOD_ACTIVATION_RECEIPT_MISSING' }
    try { Assert-CcodActivationReceiptPathSafe -Root $Root -Path $directory } catch { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    $terminal = @(
        foreach ($phase in @('Ready','Failed')) {
            $candidate = Join-Path $directory ("$ExpectedActivationId.$phase.json")
            if ([IO.File]::Exists($candidate)) { $candidate }
        }
    )
    if ($terminal.Count -eq 0) {
        if (Test-CcodActivationReceiptObserved -Root $Root -ExpectedActivationId $ExpectedActivationId) { throw 'CCOD_ACTIVATION_RECEIPT_NOT_READY' }
        throw 'CCOD_ACTIVATION_RECEIPT_MISSING'
    }
    if ($terminal.Count -ne 1) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    $path = $terminal[0]
    try {
        Assert-CcodActivationReceiptPathSafe -Root $Root -Path $path
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -le 0 -or $item.Length -gt $script:CcodActivationReceiptMaximumBytes) { throw 'invalid receipt file' }
        $content = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
        if ($content.TrimStart()[0] -cne '{' -or $content.TrimEnd()[-1] -cne '}') { throw 'receipt is not one object' }
        $receipt = $content | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    if ($receipt -isnot [pscustomobject]) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    $actual = @($receipt.PSObject.Properties.Name)
    if ($actual.Count -ne $script:CcodActivationReceiptFields.Count) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    for ($index=0;$index-lt$actual.Count;$index++) { if ($actual[$index] -cne $script:CcodActivationReceiptFields[$index]) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' } }
    if ($receipt.schemaVersion -isnot [int] -or $receipt.schemaVersion -ne 1 -or
        -not (Test-CcodCanonicalGuid $receipt.activationId) -or $receipt.activationId -cne $ExpectedActivationId -or
        $receipt.phase -isnot [string] -or $script:CcodActivationReceiptPhases -cnotcontains $receipt.phase -or
        $receipt.ready -isnot [bool] -or
        ($null -ne $receipt.runtimeId -and ($receipt.runtimeId -isnot [string] -or $receipt.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
        ($null -ne $receipt.previousRuntimeId -and ($receipt.previousRuntimeId -isnot [string] -or $receipt.previousRuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
        -not (Test-CcodCanonicalUtc $receipt.startedAtUtc) -or -not (Test-CcodCanonicalUtc $receipt.updatedAtUtc)) {
        throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
    }
    $started = [DateTime]::ParseExact($receipt.startedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $updated = [DateTime]::ParseExact($receipt.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if ($updated -lt $started -or
        ($receipt.phase -ceq 'Ready' -and ($receipt.runtimeId -isnot [string] -or -not $receipt.ready -or $null -ne $receipt.errorCode)) -or
        ($receipt.phase -ceq 'Failed' -and ($receipt.ready -or $receipt.errorCode -isnot [string] -or $receipt.errorCode -cnotmatch '^CCOD_[A-Z0-9_]{1,96}$')) -or
        ($receipt.phase -cnotin @('Ready','Failed') -and ($receipt.ready -or $null -ne $receipt.errorCode))) {
        throw 'CCOD_ACTIVATION_RECEIPT_INVALID'
    }
    if ([IO.Path]::GetFileName($path) -cne ("$ExpectedActivationId.$($receipt.phase).json")) { throw 'CCOD_ACTIVATION_RECEIPT_INVALID' }
    return $receipt
}

function ConvertTo-CcodNativeProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') { $slashes++; continue }
        if ($character -eq [char]'"') {
            [void]$quoted.Append(('\' * (($slashes * 2) + 1)))
            [void]$quoted.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$quoted.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$quoted.Append($character)
    }
    if ($slashes -gt 0) { [void]$quoted.Append(('\' * ($slashes * 2))) }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Stop-CcodOwnedInstallProcess {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    $boundedStopProven = $false
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        $boundedStopProven = $Process.WaitForExit(5000) -and $Process.HasExited
    } catch { }
    if ($boundedStopProven) { return }
    while ($true) {
        try {
            if (-not $Process.HasExited) { $Process.Kill() }
            [void]$Process.WaitForExit()
            if ($Process.HasExited) { return }
        } catch { }
        [Threading.Thread]::Sleep(100)
    }
}

function Invoke-CcodOwnedInstallWorker {
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$InstallScript,
        [Parameter(Mandatory)][string]$VerifiedPayloadRoot,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$SealedPackageSha256,
        [Parameter(Mandatory)][int]$FirstReceiptTimeout,
        [Parameter(Mandatory)][int]$ActivationTimeout
    )
    $process = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $firstReceiptObserved = $false
    try {
        $arguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $InstallScript,
            '-InstallRoot',
            $StateRoot,
            '-EnableCandidateCompatibleUpdates',
            '-ActivationId',
            $ActivationId
        )
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
            $arguments += @(
                '-ExpectedVersion',$ExpectedVersion,
                '-PayloadManifestPath',(Join-Path $VerifiedPayloadRoot 'installer-payload.manifest.json'),
                '-ExpectedPayloadManifestSha256',$ExpectedPayloadManifestSha256
            )
        }
        if (-not [string]::IsNullOrWhiteSpace($SealedPackageSha256)) {
            $arguments += @('-SealedPackageSha256',$SealedPackageSha256)
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $PowerShellPath
        $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CcodNativeProcessArgument ([string]$_) }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'CCOD_ACTIVATION_WORKER_START_FAILED' }
        while (-not $process.HasExited) {
            if (-not $firstReceiptObserved) {
                try {
                    $firstReceiptObserved = Test-CcodActivationReceiptObserved -Root $StateRoot -ExpectedActivationId $ActivationId
                } catch { }
            }
            if (-not $firstReceiptObserved -and $clock.ElapsedMilliseconds -ge $FirstReceiptTimeout) {
                Stop-CcodOwnedInstallProcess -Process $process
                throw 'CCOD_ACTIVATION_FIRST_RECEIPT_TIMEOUT'
            }
            if ($clock.ElapsedMilliseconds -ge $ActivationTimeout) {
                Stop-CcodOwnedInstallProcess -Process $process
                throw 'CCOD_ACTIVATION_TIMEOUT'
            }
            [void]$process.WaitForExit(50)
        }
        [void]$process.WaitForExit()
        return [int]$process.ExitCode
    } finally {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) { Stop-CcodOwnedInstallProcess -Process $process }
            } finally {
                $process.Dispose()
            }
        }
    }
}

function Invoke-CcodBoundedReceiptValidator {
    param([Parameter(Mandatory)][int]$TimeoutMilliseconds)
    $process = $null
    try {
        $hostExecutable = Join-Path $PSHOME 'powershell.exe'
        if (-not [IO.File]::Exists($hostExecutable) -or -not [IO.File]::Exists($PSCommandPath)) {
            throw 'CCOD_ACTIVATION_VALIDATOR_START_FAILED'
        }
        $arguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $PSCommandPath,
            '-AppRoot',
            $AppRoot,
            '-PayloadRoot',
            $PayloadRoot,
            '-InstallRoot',
            $InstallRoot,
            '-ValidateReceiptOnly',
            '-ActivationId',
            $ActivationId
        )
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) { $arguments += @('-ExpectedVersion',$ExpectedVersion,'-ExpectedPayloadManifestSha256',$ExpectedPayloadManifestSha256) }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $hostExecutable
        $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CcodNativeProcessArgument ([string]$_) }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'CCOD_ACTIVATION_VALIDATOR_START_FAILED' }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
            } catch { }
            Write-Error 'CCOD_ACTIVATION_VALIDATOR_TIMEOUT' -ErrorAction Continue
            return 3
        }
        $exitCode = [int]$process.ExitCode
        if ($exitCode -eq 0 -or $exitCode -eq 2) { return $exitCode }
        Write-Error 'CCOD_ACTIVATION_RECEIPT_INVALID' -ErrorAction Continue
        return 3
    } catch {
        Write-Error 'CCOD_ACTIVATION_VALIDATOR_START_FAILED' -ErrorAction Continue
        return 3
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Read-CcodFinalActivationReceipt {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedActivationId)
    $receipt = Read-CcodTerminalActivationReceipt -Root $Root -ExpectedActivationId $ExpectedActivationId
    if ($receipt.phase -cne 'Ready') { throw 'CCOD_ACTIVATION_RECEIPT_NOT_READY' }
    return $receipt
}

function Show-CcodActivationFailure {
    param([Parameter(Mandatory)][string]$Code)
    if (-not $Prompt -or $NoUi) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [Windows.Forms.MessageBox]::Show("CodexRemote-fix did not reach verified readiness ($Code). The previous runtime was retained for recovery; no Codex restart was attempted.",'CodexRemote-fix',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
}

if ($ValidateReceiptOnly -and $ValidateReceiptWithTimeout) { Write-Error 'CCOD_ACTIVATION_VALIDATOR_MODE_INVALID' -ErrorAction Continue; exit 3 }
$packageBound = -not [string]::IsNullOrWhiteSpace($PackagePath) -or -not [string]::IsNullOrWhiteSpace($PackageManifestPath) -or -not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedPackageManifestSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedGitCommit)
$packageSeal = $null
$packageAppRoot = $null
$payloadSeal = $null
try {
if ($packageBound) {
    if ([string]::IsNullOrWhiteSpace($PackagePath) -or [string]::IsNullOrWhiteSpace($PackageManifestPath) -or [string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or [string]::IsNullOrWhiteSpace($ExpectedPackageManifestSha256) -or [string]::IsNullOrWhiteSpace($ExpectedVersion) -or [string]::IsNullOrWhiteSpace($ExpectedGitCommit)) { throw 'CCOD_INSTALLER_PACKAGE_INVALID' }
    try {
        $packageSeal = Open-CcodInstallerPackageSeal -PackagePath $PackagePath -PackageManifestPath $PackageManifestPath -ExpectedPackageSha256 $ExpectedPackageSha256 -ExpectedPackageManifestSha256 $ExpectedPackageManifestSha256 -ExpectedVersion $ExpectedVersion -ExpectedGitCommit $ExpectedGitCommit
        $packageAppRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-package-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory((Join-Path $packageAppRoot 'payload')) | Out-Null
        $PayloadRoot = Join-Path (Join-Path $packageAppRoot 'payload') $ExpectedVersion
        [void](Expand-CcodInstallerPackageSeal -Seal $packageSeal -DestinationRoot $PayloadRoot)
        $AppRoot = $packageAppRoot
        $ExpectedPayloadManifestSha256 = [string]$packageSeal.PayloadManifestSha256
    } catch {
        $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
        $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_INSTALLER_PACKAGE_INVALID' }
        Write-Error $code -ErrorAction Continue
        exit 3
    }
} else {
    if ([string]::IsNullOrWhiteSpace($AppRoot)) { Write-Error 'CCOD_INSTALL_INPUT_INVALID' -ErrorAction Continue; exit 3 }
    if ([string]::IsNullOrWhiteSpace($PayloadRoot)) { $PayloadRoot = $AppRoot }
}

function Test-CcodActivationReceiptObserved {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedActivationId)
    $directory = Join-Path $Root 'state\activation-receipts'
    if (-not [IO.Directory]::Exists($directory)) { return $false }
    try {
        Assert-CcodActivationReceiptPathSafe -Root $Root -Path $directory
        foreach ($phase in $script:CcodActivationReceiptPhases) {
            $path = Join-Path $directory ("$ExpectedActivationId.$phase.json")
            if ([IO.File]::Exists($path)) {
                Assert-CcodActivationReceiptPathSafe -Root $Root -Path $path
                return $true
            }
        }
    } catch { return $false }
    return $false
}
$PayloadRoot = [IO.Path]::GetFullPath($PayloadRoot)
if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    try { $payloadSeal = New-CcodActivationPayloadSeal -AppRoot $AppRoot -Root $PayloadRoot -Version $ExpectedVersion -ExpectedManifestSha256 $ExpectedPayloadManifestSha256 }
    catch {
        $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
        $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        Write-Error $code -ErrorAction Continue
        exit 3
    }
}
if ([string]::IsNullOrWhiteSpace($ActivationId)) {
    if ($ValidateReceiptOnly -or $ValidateReceiptWithTimeout) { Write-Error 'CCOD_ACTIVATION_ID_INVALID' -ErrorAction Continue; exit 3 }
    $ActivationId = [guid]::NewGuid().ToString('D')
}
if (-not (Test-CcodCanonicalGuid $ActivationId)) { Write-Error 'CCOD_ACTIVATION_ID_INVALID' -ErrorAction Continue; exit 3 }
if ($FirstReceiptTimeoutMilliseconds -gt $ActivationTimeoutMilliseconds) { Write-Error 'CCOD_ACTIVATION_TIMEOUT_INVALID' -ErrorAction Continue; exit 3 }
if ($ValidateReceiptWithTimeout) {
    $validationResult = Invoke-CcodBoundedReceiptValidator -TimeoutMilliseconds $ValidationTimeoutMilliseconds
    exit $validationResult
}
if ($ValidateReceiptOnly) {
    try {
        $terminalReceipt = Read-CcodTerminalActivationReceipt -Root ([IO.Path]::GetFullPath($InstallRoot)) -ExpectedActivationId $ActivationId
        if ($terminalReceipt.phase -ceq 'Ready') {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
                Assert-CcodActivatedRuntimeVersion -Root ([IO.Path]::GetFullPath($InstallRoot)) -RuntimeId ([string]$terminalReceipt.runtimeId) -Version $ExpectedVersion -RuntimeModulePath (Join-Path $payloadSeal.StageRoot 'src\persistence\modules\RuntimeManifest.psm1')
            }
            exit 0
        }
        if ($terminalReceipt.phase -ceq 'Failed') { exit 2 }
        throw 'CCOD_ACTIVATION_RECEIPT_NOT_READY'
    } catch {
        $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
        $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_ACTIVATION_RECEIPT_INVALID' }
        Write-Error $code -ErrorAction Continue
        exit 3
    }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $root = [IO.Path]::GetFullPath($AppRoot)
    $stateRoot = [IO.Path]::GetFullPath($InstallRoot)
    $executionPayloadRoot = if ($null -ne $payloadSeal) { [string]$payloadSeal.StageRoot } else { $PayloadRoot }
    $installScript = Join-Path $executionPayloadRoot 'Install-CodexControlOtherDevices.ps1'
    if (-not [IO.File]::Exists($installScript)) { throw 'CCOD_ACTIVATION_INSTALL_SCRIPT_MISSING' }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    Write-CcodActivationRecord -Code 'STARTED' -DurationMilliseconds $clock.ElapsedMilliseconds
    $installExitCode = Invoke-CcodOwnedInstallWorker -PowerShellPath $powershell -InstallScript $installScript -VerifiedPayloadRoot $executionPayloadRoot -StateRoot $stateRoot -SealedPackageSha256 $(if($packageBound){$ExpectedPackageSha256}else{$null}) -FirstReceiptTimeout $FirstReceiptTimeoutMilliseconds -ActivationTimeout $ActivationTimeoutMilliseconds
    if ($installExitCode -ne 0) {
        $reportedErrorCode = $null
        try {
            $failedReceipt = Read-CcodTerminalActivationReceipt -Root $stateRoot -ExpectedActivationId $ActivationId
            if ($failedReceipt.phase -ceq 'Failed') { $reportedErrorCode = [string]$failedReceipt.errorCode }
        } catch { }
        if ($reportedErrorCode -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { throw $reportedErrorCode }
        throw 'CCOD_ACTIVATION_RUNTIME_FAILED'
    }
    $activationReceipt = Read-CcodFinalActivationReceipt -Root $stateRoot -ExpectedActivationId $ActivationId
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        Assert-CcodActivatedRuntimeVersion -Root $stateRoot -RuntimeId ([string]$activationReceipt.runtimeId) -Version $ExpectedVersion -RuntimeModulePath (Join-Path $payloadSeal.StageRoot 'src\persistence\modules\RuntimeManifest.psm1')
    }
    Write-CcodActivationRecord -Code 'RUNTIME_ACTIVATED' -DurationMilliseconds $clock.ElapsedMilliseconds
} catch {
    $candidate = ([string]$_.FullyQualifiedErrorId -split ',')[0]
    $code = if ($candidate -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $candidate } elseif ($_.Exception.Message -cmatch '^CCOD_[A-Z0-9_]{1,96}$') { $Matches[0] } else { 'CCOD_ACTIVATION_FAILED' }
    Write-CcodActivationRecord -Code $code -DurationMilliseconds $clock.ElapsedMilliseconds
    Show-CcodActivationFailure -Code $code
    Write-Error $code -ErrorAction Continue
    exit 1
}

if ($Prompt) {
    $restartConfirmed = $false
    try {
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        if ([IO.File]::Exists($promptScript)) {
            $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$promptScript,'-AppRoot',$root,'-InstallRoot',$stateRoot,'-ActivationId',$ActivationId)
            if ($NoUi) { $arguments += '-NoUi' }
            $null = & $powershell @arguments
            $restartConfirmed = ($LASTEXITCODE -eq 0)
        }
    } catch { $restartConfirmed = $false }
    if (-not $restartConfirmed) {
        Write-CcodActivationRecord -Code 'RESTART_UNCONFIRMED' -DurationMilliseconds $clock.ElapsedMilliseconds
        exit 0
    }
}

Write-CcodActivationRecord -Code 'COMPLETED' -DurationMilliseconds $clock.ElapsedMilliseconds
exit 0
} finally {
    Close-CcodActivationPayloadSeal -Seal $payloadSeal
    Close-CcodInstallerPackageSeal -Seal $packageSeal
    if ($null -ne $packageAppRoot -and [IO.Directory]::Exists($packageAppRoot)) { Remove-Item -LiteralPath $packageAppRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
