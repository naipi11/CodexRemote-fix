Set-StrictMode -Version Latest

function Throw-CcodError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [System.Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [System.Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetItem = { param([string]$Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        UtcNow = { [DateTime]::UtcNow }
        NewGuid = { [guid]::NewGuid() }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
}

function Get-CcodPathItem {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Adapters
    )

    return & $Adapters.GetItem $Path
}

function Test-CcodNoReparseAncestor {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf,
        [hashtable]$Adapters
    )

    $rootWithoutSeparator = $Root.TrimEnd('\')
    $rootItem = Get-CcodPathItem -Path $rootWithoutSeparator -Adapters $Adapters
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-CcodError 'CCOD_REPARSE_PATH' 'Install root is a reparse point' $Root
    }

    $relative = $Path.Substring($Root.Length)
    $cursor = $rootWithoutSeparator
    foreach ($segment in ($relative -split '\\' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        try {
            $item = Get-CcodPathItem -Path $cursor -Adapters $Adapters
        } catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissingLeaf) { break }
            Throw-CcodError 'CCOD_PATH_MISSING' 'Required contained path is missing' $cursor
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-CcodError 'CCOD_REPARSE_PATH' 'Contained path is a reparse point' $cursor
        }
    }
}

function Resolve-CcodContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$AllowMissingLeaf,
        [hashtable]$Adapters
    )

    $Adapters = Get-CcodAdapters -Adapters $Adapters
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Absolute child path rejected' $RelativePath
    }

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Path escapes root' $candidate
    }

    Test-CcodNoReparseAncestor -Root $rootFull -Path $candidate -AllowMissingLeaf:$AllowMissingLeaf -Adapters $Adapters
    return $candidate
}

function Initialize-CcodNativeAtomicFile {
    if ($null -ne ('CcodNativeAtomicFile' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CcodNativeAtomicFile
{
    private const uint GenericWrite = 0x40000000U;
    private const uint Delete = 0x00010000U;
    private const uint CreateNew = 1U;
    private const uint FileAttributeNormal = 0x00000080U;
    private const uint FileFlagWriteThrough = 0x80000000U;
    private const int FileRenameInfo = 3;
    private const int FileDispositionInfo = 4;

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle file,
        int fileInformationClass,
        IntPtr fileInformation,
        uint bufferSize);

    public static FileStream CreateNewFile(string path)
    {
        SafeFileHandle handle = CreateFile(
            path,
            GenericWrite | Delete,
            0,
            IntPtr.Zero,
            CreateNew,
            FileAttributeNormal | FileFlagWriteThrough,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            int errorCode = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new IOException("Could not create an owned atomic file", new Win32Exception(errorCode));
        }

        try
        {
            return new FileStream(handle, FileAccess.Write, 4096, false);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    public static int MoveFileByHandle(SafeFileHandle source, string destination)
    {
        return MoveFileByHandle(source, destination, true);
    }

    public static int MoveFileByHandleNoReplace(SafeFileHandle source, string destination)
    {
        return MoveFileByHandle(source, destination, false);
    }

    public static int DeleteFileByHandle(SafeFileHandle file)
    {
        IntPtr buffer = Marshal.AllocHGlobal(1);
        try
        {
            Marshal.WriteByte(buffer, 0, 1);
            return SetFileInformationByHandle(file, FileDispositionInfo, buffer, 1)
                ? 0
                : Marshal.GetLastWin32Error();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static int MoveFileByHandle(SafeFileHandle source, string destination, bool replaceIfExists)
    {
        string fullPath = Path.GetFullPath(destination);
        string nativePath = fullPath.StartsWith(@"\\", StringComparison.Ordinal)
            ? @"\??\UNC\" + fullPath.Substring(2)
            : @"\??\" + fullPath;
        byte[] name = Encoding.Unicode.GetBytes(nativePath);
        int rootDirectoryOffset = IntPtr.Size;
        int fileNameLengthOffset = rootDirectoryOffset + IntPtr.Size;
        int fileNameOffset = fileNameLengthOffset + sizeof(uint);
        int bufferSize = checked(fileNameOffset + name.Length + sizeof(char));
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);

        try
        {
            for (int index = 0; index < bufferSize; index++)
            {
                Marshal.WriteByte(buffer, index, 0);
            }
            Marshal.WriteByte(buffer, 0, replaceIfExists ? (byte)1 : (byte)0);
            Marshal.WriteIntPtr(buffer, rootDirectoryOffset, IntPtr.Zero);
            Marshal.WriteInt32(buffer, fileNameLengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, fileNameOffset), name.Length);

            return SetFileInformationByHandle(source, FileRenameInfo, buffer, (uint)bufferSize)
                ? 0
                : Marshal.GetLastWin32Error();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

function Get-CcodAtomicWriteAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetRandomFileName = { param([string]$Purpose) [IO.Path]::GetRandomFileName() }
        FileExists = { param([string]$Path) [IO.File]::Exists($Path) }
        CreateNewFile = { param([string]$Path) [CcodNativeAtomicFile]::CreateNewFile($Path) }
        CommitFileByHandle = {
            param([IO.FileStream]$Source, [string]$Destination)
            $errorCode = [CcodNativeAtomicFile]::MoveFileByHandle($Source.SafeFileHandle, $Destination)
            return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
        }
        CommitFileByHandleNoReplace = {
            param([IO.FileStream]$Source, [string]$Destination)
            $errorCode = [CcodNativeAtomicFile]::MoveFileByHandleNoReplace($Source.SafeFileHandle, $Destination)
            return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
        }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
}

function New-CcodAtomicOwnedFile {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $leaf = [string](& $Adapters.GetRandomFileName $Purpose)
        if ([string]::IsNullOrWhiteSpace($leaf) -or [IO.Path]::IsPathRooted($leaf) -or $leaf -ne [IO.Path]::GetFileName($leaf)) {
            Throw-CcodError 'CCOD_ATOMIC_NAME_INVALID' 'Atomic JSON helper supplied an unsafe sibling name' $leaf
        }
        $candidate = Join-Path $Directory $leaf
        try {
            return [pscustomobject]@{ Path = $candidate; Stream = (& $Adapters.CreateNewFile $candidate) }
        } catch [IO.IOException] {
            continue
        }
    }
    Throw-CcodError 'CCOD_ATOMIC_NAME_EXHAUSTED' 'Could not atomically claim a unique JSON sibling name' $Directory
}

function Get-CcodByteFingerprint {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [pscustomobject]@{
            Length = [int64]$Bytes.LongLength
            Sha256 = [BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
        }
    } finally {
        $sha256.Dispose()
    }
}

function Test-CcodPathMatchesFingerprint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Fingerprint,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    if (-not (& $Adapters.FileExists $Path)) { return $false }
    try {
        $actual = Get-CcodByteFingerprint -Bytes ([IO.File]::ReadAllBytes($Path))
        return $actual.Length -eq $Fingerprint.Length -and $actual.Sha256 -ceq $Fingerprint.Sha256
    } catch {
        return $false
    }
}

function Write-CcodOwnedBytes {
    param(
        [Parameter(Mandatory)]$OwnedFile,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [switch]$KeepOpen
    )

    try {
        $OwnedFile.Stream.Write($Bytes, 0, $Bytes.Length)
        if ($OwnedFile.Stream -is [IO.FileStream]) {
            $OwnedFile.Stream.Flush($true)
        } else {
            $OwnedFile.Stream.Flush()
        }
    } finally {
        if (-not $KeepOpen) {
            $OwnedFile.Stream.Dispose()
        }
    }
}

function New-CcodAtomicRecoveryArtifact {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$OldBytes,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $artifact = New-CcodAtomicOwnedFile -Directory $Directory -Purpose 'recovery' -Adapters $Adapters
    Write-CcodOwnedBytes -OwnedFile $artifact -Bytes $OldBytes
    return $artifact.Path
}

function Restore-CcodAtomicOldTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$OldBytes,
        [Parameter(Mandatory)]$OldFingerprint,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    try {
        $target = [pscustomobject]@{ Path = $Path; Stream = (& $Adapters.CreateNewFile $Path) }
    } catch [IO.IOException] {
        return $false
    }
    Write-CcodOwnedBytes -OwnedFile $target -Bytes $OldBytes
    return Test-CcodPathMatchesFingerprint -Path $Path -Fingerprint $OldFingerprint -Adapters $Adapters
}

function Write-CcodAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$Compress,
        [hashtable]$Adapters
    )

    Initialize-CcodNativeAtomicFile
    $Adapters = Get-CcodAtomicWriteAdapters -Adapters $Adapters
    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $json = ($Value | ConvertTo-Json -Depth 16 -Compress:$Compress) + "`n"
    $encoding = [Text.UTF8Encoding]::new($false)
    $temporary = New-CcodAtomicOwnedFile -Directory $directory -Purpose 'replacement' -Adapters $Adapters
    $oldBytes = $null
    $oldFingerprint = $null
    try {
        Write-CcodOwnedBytes -OwnedFile $temporary -Bytes $encoding.GetBytes($json) -KeepOpen
        if (& $Adapters.FileExists $Path) {
            $oldBytes = [IO.File]::ReadAllBytes($Path)
            $oldFingerprint = Get-CcodByteFingerprint -Bytes $oldBytes
        }
        $result = & $Adapters.CommitFileByHandle $temporary.Stream $Path
    } finally {
        $temporary.Stream.Dispose()
    }

    if ($result.Success) { return }

    if ($null -eq $oldBytes) {
        Throw-CcodError 'CCOD_ATOMIC_REPLACE_FAILED' "Native atomic JSON commit failed with Windows error $($result.ErrorCode); no prior target required recovery" $Path
    }

    if (Test-CcodPathMatchesFingerprint -Path $Path -Fingerprint $oldFingerprint -Adapters $Adapters) {
        Throw-CcodError 'CCOD_ATOMIC_REPLACE_FAILED' "Native atomic JSON commit failed with Windows error $($result.ErrorCode); the old target remains valid" $Path
    }

    if (-not (& $Adapters.FileExists $Path) -and (Restore-CcodAtomicOldTarget -Path $Path -OldBytes $oldBytes -OldFingerprint $oldFingerprint -Adapters $Adapters)) {
        Throw-CcodError 'CCOD_ATOMIC_REPLACE_FAILED' "Native atomic JSON commit failed with Windows error $($result.ErrorCode); the old target was restored" $Path
    }

    $artifact = New-CcodAtomicRecoveryArtifact -Directory $directory -OldBytes $oldBytes -Adapters $Adapters
    Throw-CcodError 'CCOD_ATOMIC_RECOVERY_FAILED' "Native atomic JSON commit failed with Windows error $($result.ErrorCode); old bytes were retained in a recovery artifact" ([pscustomobject]@{ TargetPath = $Path; RecoveryArtifact = $artifact })
}

function Write-CcodAtomicJsonIfAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [hashtable]$Adapters
    )

    Initialize-CcodNativeAtomicFile
    $Adapters = Get-CcodAtomicWriteAdapters -Adapters $Adapters
    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $json = ($Value | ConvertTo-Json -Depth 16) + "`n"
    $encoding = [Text.UTF8Encoding]::new($false)
    $temporary = New-CcodAtomicOwnedFile -Directory $directory -Purpose 'create' -Adapters $Adapters
    $committed = $false
    $result = $null
    $failure = $null
    $cleanupError = 0
    try {
        Write-CcodOwnedBytes -OwnedFile $temporary -Bytes $encoding.GetBytes($json) -KeepOpen
        $result = & $Adapters.CommitFileByHandleNoReplace $temporary.Stream $Path
        $committed = $result.Success
    } catch {
        $failure = $_
    } finally {
        if (-not $committed) { $cleanupError = [CcodNativeAtomicFile]::DeleteFileByHandle($temporary.Stream.SafeFileHandle) }
        $temporary.Stream.Dispose()
    }

    if ($cleanupError -ne 0) { Throw-CcodError 'CCOD_ATOMIC_CLEANUP_FAILED' "Could not remove an uncommitted atomic JSON file (Windows error $cleanupError)" $temporary.Path }
    if ($null -ne $failure) { throw $failure }
    if ($committed) { return }
    if ($result.ErrorCode -in @(80, 183)) {
        Throw-CcodError 'CCOD_ATOMIC_TARGET_EXISTS' 'Atomic JSON create refused to overwrite an existing target' $Path
    }
    Throw-CcodError 'CCOD_ATOMIC_CREATE_FAILED' "Native atomic JSON create failed with Windows error $($result.ErrorCode)" $Path
}

function Test-CcodJsonHasNoDuplicateProperties {
    param([AllowNull()][string]$Json)

    if ($null -eq $Json) { return $false }
    $objects = [Collections.Generic.Stack[object]]::new()
    for ($index = 0; $index -lt $Json.Length; $index++) {
        $character = $Json[$index]
        if ($character -eq '{') {
            $objects.Push([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
            continue
        }
        if ($character -eq '}') {
            if ($objects.Count -eq 0) { return $false }
            [void]$objects.Pop()
            continue
        }
        if ($character -ne '"') { continue }

        $name = [Text.StringBuilder]::new()
        $index++
        while ($index -lt $Json.Length) {
            $character = $Json[$index]
            if ($character -eq '"') { break }
            if ($character -ne [char]92) {
                [void]$name.Append($character)
                $index++
                continue
            }

            $index++
            if ($index -ge $Json.Length) { return $false }
            $escape = $Json[$index]
            if ($escape -eq 'u') {
                if ($index + 4 -ge $Json.Length) { return $false }
                try {
                    [void]$name.Append([char][Convert]::ToInt32($Json.Substring($index + 1, 4), 16))
                } catch {
                    return $false
                }
                $index += 5
                continue
            }
            switch ([string]$escape) {
                '"' { $decoded = '"' }
                '\' { $decoded = [char]92 }
                '/' { $decoded = '/' }
                'b' { $decoded = [char]8 }
                'f' { $decoded = [char]12 }
                'n' { $decoded = [char]10 }
                'r' { $decoded = [char]13 }
                't' { $decoded = [char]9 }
                default { return $false }
            }
            [void]$name.Append($decoded)
            $index++
        }
        if ($index -ge $Json.Length) { return $false }

        $next = $index + 1
        while ($next -lt $Json.Length -and [char]::IsWhiteSpace($Json[$next])) { $next++ }
        if ($next -lt $Json.Length -and $Json[$next] -eq ':') {
            if ($objects.Count -eq 0 -or -not $objects.Peek().Add($name.ToString())) { return $false }
        }
    }
    return $objects.Count -eq 0
}

function Convert-CcodJsonDateValuesInPlace {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            [void]($normalized = Convert-CcodJsonDateValuesInPlace -Value $property.Value)
            [void]($property.Value = $normalized)
        }
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            [void]($normalized = Convert-CcodJsonDateValuesInPlace -Value $Value[$key])
            [void]($Value[$key] = $normalized)
        }
        return $Value
    }
    if ($Value -is [Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            [void]($normalized = Convert-CcodJsonDateValuesInPlace -Value $Value[$index])
            [void]($Value[$index] = $normalized)
        }
        return ,$Value
    }
    return $Value
}

function Read-CcodStrictJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ExpectedSchema,
        [Parameter(Mandatory)][string]$Kind
    )

    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodError 'CCOD_STATE_MISSING' "Required $Kind state is missing" $Path
    }

    try {
        $json = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    } catch {
        Throw-CcodError 'CCOD_STATE_MALFORMED' "$Kind state is not valid JSON" $Path
    }
    if (-not (Test-CcodJsonHasNoDuplicateProperties -Json $json)) {
        Throw-CcodError 'CCOD_STATE_MALFORMED' "$Kind state is not valid JSON" $Path
    }
    try {
        $value = $json | ConvertFrom-Json -ErrorAction Stop
        $value = Convert-CcodJsonDateValuesInPlace -Value $value
    } catch {
        Throw-CcodError 'CCOD_STATE_MALFORMED' "$Kind state is not valid JSON" $Path
    }

    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        Throw-CcodError 'CCOD_STATE_MALFORMED' "$Kind state must have an object root" $Path
    }

    $schemaProperty = $value.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or $schemaProperty.Value -ne $ExpectedSchema) {
        Throw-CcodError 'CCOD_SCHEMA_UNSUPPORTED' "$Kind state has an unsupported schema" $Path
    }

    return $value
}

function Move-CcodCorruptState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Root = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'),
        [hashtable]$Adapters
    )

    $source = [IO.Path]::GetFullPath($Path)
    $Adapters = Get-CcodAdapters -Adapters $Adapters
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $source.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Corrupt state is outside the trusted root' $source
    }

    $relative = $source.Substring($rootFull.Length)
    $source = Resolve-CcodContainedPath -Root $Root -RelativePath $relative -Adapters $Adapters
    if (-not [IO.File]::Exists($source)) {
        Throw-CcodError 'CCOD_STATE_MISSING' 'Corrupt state file is missing' $source
    }

    $sourceItem = Get-CcodPathItem -Path $source -Adapters $Adapters
    if ($sourceItem.PSIsContainer) {
        Throw-CcodError 'CCOD_REPARSE_PATH' 'Corrupt state must be a regular file' $source
    }

    $directory = Split-Path -Path $source -Parent
    $utcNow = & $Adapters.UtcNow
    $newGuid = & $Adapters.NewGuid
    $destination = Join-Path $directory ((Split-Path $source -Leaf) + '.corrupt.' + $utcNow.ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.' + $newGuid.ToString('N'))
    [IO.File]::Move($source, $destination)
    return $destination
}

function Remove-CcodUnsafeLogHistory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Int64]$Limit
    )

    $directory = Split-Path -Path $Path -Parent
    $leaf = Split-Path -Path $Path -Leaf
    $pattern = '^' + [Regex]::Escape($leaf) + '\.(\d+)$'
    foreach ($item in Get-ChildItem -LiteralPath $directory -File -Force) {
        if ($item.Name -match $pattern) {
            [Int64]$generation = $Matches[1]
            if ($generation -gt 10 -or $item.Length -gt $Limit) {
                [IO.File]::Delete($item.FullName)
            }
        }
    }
}

function Write-CcodRotatingLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $limit = 2MB
    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $encoding = [Text.UTF8Encoding]::new($false)
    $entry = $Message + [Environment]::NewLine
    $entryLength = $encoding.GetByteCount($entry)
    if ($entryLength -gt $limit) {
        Throw-CcodError 'CCOD_LOG_ENTRY_TOO_LARGE' 'A single log entry exceeds the 2 MiB limit' $Path
    }
    Remove-CcodUnsafeLogHistory -Path $Path -Limit $limit

    if ([IO.File]::Exists($Path)) {
        $currentLength = (Get-Item -LiteralPath $Path).Length
        if ($currentLength -gt 0 -and ($currentLength + $entryLength -gt $limit)) {
            if ($currentLength -gt $limit) {
                [IO.File]::Delete($Path)
            } else {
                $oldest = "$Path.10"
                if ([IO.File]::Exists($oldest)) { [IO.File]::Delete($oldest) }
                for ($generation = 9; $generation -ge 1; $generation--) {
                    $source = "$Path.$generation"
                    if ([IO.File]::Exists($source)) {
                        [IO.File]::Move($source, "$Path.$($generation + 1)")
                    }
                }
                [IO.File]::Move($Path, "$Path.1")
            }
        }
    }

    [IO.File]::AppendAllText($Path, $entry, $encoding)
}

Export-ModuleMember -Function Resolve-CcodContainedPath, Read-CcodStrictJson, Write-CcodAtomicJson, Write-CcodAtomicJsonIfAbsent, Move-CcodCorruptState, Write-CcodRotatingLog
