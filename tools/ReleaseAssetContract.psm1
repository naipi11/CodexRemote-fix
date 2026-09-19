Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 7.5+ materializes ISO-8601 JSON strings as [datetime]. These modules
# validate provenance timestamps as canonical UTC text, so read every JSON document
# with -DateKind String when the shell offers it and keep the Windows PowerShell 5.1
# behavior (dates stay text) identical across both shells.
$script:CcodReleaseContractJsonKeepsDateText = @((Get-Command ConvertFrom-Json).Parameters.Keys) -contains 'DateKind'

function ConvertFrom-CcodReleaseContractJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if ($script:CcodReleaseContractJsonKeepsDateText) { return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop }
    return $Json | ConvertFrom-Json -ErrorAction Stop
}

# BEGIN CCOD TRUSTED IMPORT BOOTSTRAP
# Embedded in each independently trusted entrypoint; an unheld helper import
# cannot bootstrap its own protection. Keep copies identical (self-test enforced).
function Initialize-CcodTrustedImportLease {
    if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CcodTrustedImportLeaseV1 : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] private struct NativeTime { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeInfo
    {
        public uint Attributes;
        public NativeTime Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    private sealed class Entry
    {
        public SafeFileHandle Handle;
        public string Path;
        public bool Directory;
        public uint Volume;
        public ulong FileId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out NativeInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder value, uint length, uint flags);

    private readonly List<Entry> entries = new List<Entry>();
    private bool disposed;
    public string Path { get; private set; }
    private CcodTrustedImportLeaseV1(string path) { Path = path; }

    public static CcodTrustedImportLeaseV1 Acquire(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathRooted(path) ||
            path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
            throw new ArgumentException("Unsupported module path");
        string full = System.IO.Path.GetFullPath(path);
        string root = System.IO.Path.GetPathRoot(full);
        string extension = System.IO.Path.GetExtension(full);
        if (!String.Equals(full, path, StringComparison.OrdinalIgnoreCase) || String.IsNullOrEmpty(root) ||
            full.Substring(root.Length).IndexOf(':') >= 0 ||
            (!String.Equals(extension, ".psm1", StringComparison.OrdinalIgnoreCase) && !String.Equals(extension, ".ps1", StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Noncanonical module path");
        var lease = new CcodTrustedImportLeaseV1(full);
        try
        {
            var parents = new List<string>();
            for (DirectoryInfo parent = Directory.GetParent(full); parent != null; parent = parent.Parent)
                parents.Add(parent.FullName);
            parents.Reverse();
            if (parents.Count == 0 || !SamePath(parents[0], root)) throw new IOException("Missing module root");
            // Retain root-to-leaf authority before traversing the next component.
            foreach (string parent in parents) lease.Open(parent, true);
            lease.Open(full, false);
            lease.Revalidate();
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    private void Open(string path, bool directory)
    {
        uint access = directory ? 0x00100081U : 0x80100080U;
        uint flags = 0x00200000U | (directory ? 0x02000000U : 0U);
        // FILE_SHARE_READ only: preexisting writers/deleters must fail closed.
        SafeFileHandle handle = CreateFileW(path, access, 1U, IntPtr.Zero, 3U, flags, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
        try
        {
            NativeInfo info = Inspect(handle, path, directory);
            entries.Add(new Entry { Handle = handle, Path = path, Directory = directory, Volume = info.Volume, FileId = FileId(info) });
        }
        catch { handle.Dispose(); throw; }
    }

    private static ulong FileId(NativeInfo info) { return ((ulong)info.IndexHigh << 32) | info.IndexLow; }
    private static bool SamePath(string left, string right)
    {
        return String.Equals(left.TrimEnd('\\'), right.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    }
    private static NativeInfo Inspect(SafeFileHandle handle, string expected, bool directory)
    {
        NativeInfo info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if ((info.Attributes & 0x400U) != 0 || ((info.Attributes & 0x10U) != 0) != directory)
            throw new IOException("Unsafe module path kind");
        var value = new StringBuilder(512);
        uint length = GetFinalPathNameByHandleW(handle, value, (uint)value.Capacity, 0);
        if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length >= value.Capacity)
        {
            value.Capacity = checked((int)length + 1);
            length = GetFinalPathNameByHandleW(handle, value, (uint)value.Capacity, 0);
            if (length == 0 || length >= value.Capacity) throw new IOException("Module final path unavailable");
        }
        string final = value.ToString();
        if (final.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) final = @"\\" + final.Substring(8);
        else if (final.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) final = final.Substring(4);
        if (!SamePath(final, expected)) throw new IOException("Module final path mismatch");
        return info;
    }

    public void Revalidate()
    {
        if (disposed) throw new ObjectDisposedException("trusted module import lease");
        foreach (Entry entry in entries)
        {
            NativeInfo info = Inspect(entry.Handle, entry.Path, entry.Directory);
            if (info.Volume != entry.Volume || FileId(info) != entry.FileId) throw new IOException("Module identity changed");
        }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        for (int index = entries.Count - 1; index >= 0; index--) entries[index].Handle.Dispose();
        entries.Clear();
    }
}
'@
}

function Open-CcodTrustedImportLease {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId)
    try {
        Initialize-CcodTrustedImportLease
        return [CcodTrustedImportLeaseV1]::Acquire($Path)
    } catch {
        throw [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('Trusted module import authority could not be acquired.'),
            $ErrorId,[Management.Automation.ErrorCategory]::InvalidData,$Path)
    }
}
# END CCOD TRUSTED IMPORT BOOTSTRAP

function Initialize-CcodReleaseFileAuthority {
    if ($null -ne ('CcodReleaseFileAuthorityV1' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CcodReleaseFileIdentityV1
{
    public uint Attributes;
    public uint Volume;
    public ulong FileId;
    public uint Links;
    public string FinalPath;
    public string[] Streams;
}

public static class CcodReleaseFileAuthorityV1
{
    private const uint ListDirectory=0x00000001U, ReadAttributes=0x00000080U, Synchronize=0x00100000U, GenericRead=0x80000000U, GenericWrite=0x40000000U, DeleteAccess=0x00010000U;
    private const uint ShareRead=0x00000001U, ShareWrite=0x00000002U, ShareDelete=0x00000004U, CreateNew=1U, OpenExisting=3U, FileCreate=2U, AttributeNormal=0x00000080U, FlagWriteThrough=0x80000000U, FlagBackup=0x02000000U, FlagReparse=0x00200000U;
    private const uint AttributeDirectory=0x00000010U, AttributeReparse=0x00000400U;
    private const uint ObjectCaseInsensitive=0x00000040U, OptionSynchronous=0x00000020U, OptionNonDirectory=0x00000040U, OptionOpenReparse=0x00200000U;
    private const int FileDirectoryInformation=1, FileStreamInfo=7, FileRenameInfo=3, FileDispositionInfo=4, NtFileRenameInformation=10;
    private const int StatusNoMoreFiles=unchecked((int)0x80000006);

    [StructLayout(LayoutKind.Sequential)] private struct NativeTime { public uint Low,High; }
    [StructLayout(LayoutKind.Sequential)] private struct UnicodeString { public ushort Length,MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct ObjectAttributes { public int Length; public IntPtr RootDirectory,ObjectName; public uint Attributes; public IntPtr SecurityDescriptor,SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] private struct IoStatus { public IntPtr Status; public UIntPtr Information; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeInfo
    {
        public uint Attributes; public NativeTime Creation,Access,Write;
        public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
    }

    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out NativeInfo info);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder value,uint length,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int infoClass,IntPtr info,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool SetFileInformationByHandle(SafeFileHandle handle,int infoClass,IntPtr info,uint size);
    [DllImport("ntdll.dll")] private static extern int NtCreateFile(out IntPtr handle,uint access,ref ObjectAttributes attributes,out IoStatus io,IntPtr allocationSize,uint fileAttributes,uint share,uint disposition,uint options,IntPtr ea,uint eaLength);
    [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle handle,out IoStatus io,IntPtr info,uint length,int infoClass);
    [DllImport("ntdll.dll")] private static extern int NtQueryDirectoryFile(SafeFileHandle handle,IntPtr evt,IntPtr apc,IntPtr context,out IoStatus io,IntPtr info,uint length,int infoClass,bool single,IntPtr name,bool restart);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);

    public static SafeFileHandle OpenDirectory(string path,bool allowChildMutation)
    {
        uint share=allowChildMutation?ShareRead|ShareWrite:ShareRead;SafeFileHandle handle=CreateFileW(Path.GetFullPath(path),ListDirectory|ReadAttributes|Synchronize,share,IntPtr.Zero,OpenExisting,FlagBackup|FlagReparse,IntPtr.Zero);
        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}return handle;
    }

    public static FileStream CreateReceiptFile(string path)
    {
        SafeFileHandle handle=CreateFileW(Path.GetFullPath(path),GenericRead|GenericWrite|DeleteAccess|ReadAttributes|Synchronize,ShareRead,IntPtr.Zero,CreateNew,AttributeNormal|FlagWriteThrough|FlagReparse,IntPtr.Zero);
        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}try{return new FileStream(handle,FileAccess.ReadWrite,4096,false);}catch{handle.Dispose();throw;}
    }

    public static FileStream CreateReceiptFileRelative(SafeFileHandle directory,string leaf)
    {
        ValidateLeaf(leaf);IntPtr nameBuffer=IntPtr.Zero,unicodePointer=IntPtr.Zero;bool added=false;
        try
        {
            directory.DangerousAddRef(ref added);nameBuffer=Marshal.StringToHGlobalUni(leaf);UnicodeString unicode=new UnicodeString{Length=(ushort)(leaf.Length*2),MaximumLength=(ushort)((leaf.Length+1)*2),Buffer=nameBuffer};unicodePointer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));Marshal.StructureToPtr(unicode,unicodePointer,false);ObjectAttributes attributes=new ObjectAttributes{Length=Marshal.SizeOf(typeof(ObjectAttributes)),RootDirectory=directory.DangerousGetHandle(),ObjectName=unicodePointer,Attributes=ObjectCaseInsensitive};IoStatus io;IntPtr raw;int status=NtCreateFile(out raw,GenericRead|GenericWrite|DeleteAccess|ReadAttributes|Synchronize,ref attributes,out io,IntPtr.Zero,AttributeNormal,ShareRead,FileCreate,OptionSynchronous|OptionNonDirectory|OptionOpenReparse,IntPtr.Zero,0);if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));SafeFileHandle handle=new SafeFileHandle(raw,true);try{return new FileStream(handle,FileAccess.ReadWrite,4096,false);}catch{handle.Dispose();throw;}
        }
        finally{if(unicodePointer!=IntPtr.Zero)Marshal.FreeHGlobal(unicodePointer);if(nameBuffer!=IntPtr.Zero)Marshal.FreeHGlobal(nameBuffer);if(added)directory.DangerousRelease();}
    }

    public static FileStream OpenExclusiveOperationFile(string path)
    {
        SafeFileHandle handle=CreateFileW(Path.GetFullPath(path),GenericRead|GenericWrite|ReadAttributes|Synchronize,0U,IntPtr.Zero,4U,AttributeNormal|FlagReparse,IntPtr.Zero);
        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}try{return new FileStream(handle,FileAccess.ReadWrite,4096,false);}catch{handle.Dispose();throw;}
    }

    public static FileStream OpenReadFile(string path,bool shareExistingWriter)
    {
        uint share=ShareRead|(shareExistingWriter?ShareWrite|ShareDelete:0U);SafeFileHandle handle=CreateFileW(path,GenericRead|ReadAttributes|Synchronize,share,IntPtr.Zero,OpenExisting,FlagReparse,IntPtr.Zero);
        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}try{return new FileStream(handle,FileAccess.Read,65536,false);}catch{handle.Dispose();throw;}
    }

    public static CcodReleaseFileIdentityV1 Identity(SafeFileHandle handle)
    {
        if(handle==null||handle.IsClosed||handle.IsInvalid)throw new ObjectDisposedException("release file authority");
        NativeInfo value;if(!GetFileInformationByHandle(handle,out value))throw new Win32Exception(Marshal.GetLastWin32Error());
        return new CcodReleaseFileIdentityV1{Attributes=value.Attributes,Volume=value.Volume,FileId=((ulong)value.IndexHigh<<32)|value.IndexLow,Links=value.Links,FinalPath=FinalPath(handle),Streams=Streams(handle)};
    }

    public static bool IsDirectory(CcodReleaseFileIdentityV1 value){return(value.Attributes&AttributeDirectory)!=0U;}
    public static bool IsReparse(CcodReleaseFileIdentityV1 value){return(value.Attributes&AttributeReparse)!=0U;}

    public static int MoveNoReplace(SafeFileHandle source,string destination)
    {
        string full=Path.GetFullPath(destination),native=full.StartsWith(@"\\",StringComparison.Ordinal)?@"\??\UNC\"+full.Substring(2):@"\??\"+full;
        byte[] name=Encoding.Unicode.GetBytes(native);int rootOffset=IntPtr.Size,lengthOffset=rootOffset+IntPtr.Size,nameOffset=lengthOffset+sizeof(uint),size=checked(nameOffset+name.Length+sizeof(char));
        IntPtr buffer=Marshal.AllocHGlobal(size);try{for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,0);Marshal.WriteIntPtr(buffer,rootOffset,IntPtr.Zero);Marshal.WriteInt32(buffer,lengthOffset,name.Length);Marshal.Copy(name,0,IntPtr.Add(buffer,nameOffset),name.Length);return SetFileInformationByHandle(source,FileRenameInfo,buffer,(uint)size)?0:Marshal.GetLastWin32Error();}finally{Marshal.FreeHGlobal(buffer);}
    }

    public static int MoveNoReplaceRelative(SafeFileHandle source,SafeFileHandle directory,string leaf)
    {
        ValidateLeaf(leaf);byte[] name=Encoding.Unicode.GetBytes(leaf);int rootOffset=IntPtr.Size,lengthOffset=rootOffset+IntPtr.Size,nameOffset=lengthOffset+sizeof(uint),size=checked(nameOffset+name.Length+sizeof(char));IntPtr buffer=Marshal.AllocHGlobal(size);bool added=false;
        try{directory.DangerousAddRef(ref added);for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,0);Marshal.WriteIntPtr(buffer,rootOffset,directory.DangerousGetHandle());Marshal.WriteInt32(buffer,lengthOffset,name.Length);Marshal.Copy(name,0,IntPtr.Add(buffer,nameOffset),name.Length);IoStatus io;int status=NtSetInformationFile(source,out io,buffer,(uint)size,NtFileRenameInformation);return status<0?(int)RtlNtStatusToDosError(status):0;}finally{if(added)directory.DangerousRelease();Marshal.FreeHGlobal(buffer);}
    }

    public static int Delete(SafeFileHandle file)
    {
        IntPtr buffer=Marshal.AllocHGlobal(1);try{Marshal.WriteByte(buffer,0,1);return SetFileInformationByHandle(file,FileDispositionInfo,buffer,1)?0:Marshal.GetLastWin32Error();}finally{Marshal.FreeHGlobal(buffer);}
    }

    public static string[] EnumerateDirectory(SafeFileHandle directory)
    {
        System.Collections.Generic.List<string> values=new System.Collections.Generic.List<string>();System.Collections.Generic.HashSet<string> seen=new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);IntPtr buffer=Marshal.AllocHGlobal(65536);bool restart=true;
        try{while(true){IoStatus io;int status=NtQueryDirectoryFile(directory,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out io,buffer,65536,FileDirectoryInformation,false,IntPtr.Zero,restart);restart=false;if(status==StatusNoMoreFiles)break;if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),length=(uint)Marshal.ReadInt32(buffer,offset+60);string value=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+64),(int)length/2);if(value!="."&&value!=".."){if(!seen.Add(value))throw new InvalidDataException("duplicate directory member");values.Add(value);}if(next==0)break;offset+=(int)next;}}values.Sort(StringComparer.Ordinal);return values.ToArray();}finally{Marshal.FreeHGlobal(buffer);}
    }

    private static void ValidateLeaf(string leaf){if(String.IsNullOrWhiteSpace(leaf)||leaf=="."||leaf==".."||leaf.IndexOfAny(new[]{'\\','/',':'})>=0||leaf.EndsWith(".",StringComparison.Ordinal)||leaf.EndsWith(" ",StringComparison.Ordinal))throw new ArgumentException("unsafe leaf");}

    private static string FinalPath(SafeFileHandle handle)
    {
        StringBuilder value=new StringBuilder(512);uint length=GetFinalPathNameByHandleW(handle,value,(uint)value.Capacity,0);
        if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());if(length>=value.Capacity){value.Capacity=(int)length+1;length=GetFinalPathNameByHandleW(handle,value,(uint)value.Capacity,0);if(length==0||length>=value.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());}
        string path=value.ToString();if(path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return@"\\"+path.Substring(8);if(path.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return path.Substring(4);return path;
    }

    private static string[] Streams(SafeFileHandle handle)
    {
        IntPtr buffer=Marshal.AllocHGlobal(65536);try{if(!GetFileInformationByHandleEx(handle,FileStreamInfo,buffer,65536)){int error=Marshal.GetLastWin32Error();if(error==38)return new[]{"::$DATA"};throw new Win32Exception(error);}System.Collections.Generic.List<string> values=new System.Collections.Generic.List<string>();int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+4);values.Add(Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+24),(int)nameLength/2));if(next==0)break;offset+=(int)next;}return values.ToArray();}finally{Marshal.FreeHGlobal(buffer);}
    }
}
'@
}

Initialize-CcodReleaseFileAuthority

$script:CcodReleaseReceiptFields = @(
    'schemaVersion','assetType','assetName','assetSha256','checksumName','checksumSha256',
    'manifestName','manifestSha256','version','gitCommit','origin','workflowArtifactIdentity',
    'zoneId','defenderServiceEnabled','antivirusEnabled','realTimeProtectionEnabled',
    'defenderPlatformVersion','defenderEngineVersion','signatureVersion','signatureUpdatedAtUtc',
    'scanStartedAtUtc','scanCompletedAtUtc','detectionCount','outcome','errorCode'
)

function Throw-CcodReleaseContractError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,
        [Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Test-CcodReleaseAuthorityFinalPath {
    param([string]$Actual,[string]$Expected,[switch]$Zone)
    try{$right=[IO.Path]::GetFullPath($Expected).TrimEnd('\');$left=if($Zone){$Actual.TrimEnd('\')}else{[IO.Path]::GetFullPath($Actual).TrimEnd('\')}}catch{return $false}
    if($Zone){return $left.Equals($right+':Zone.Identifier',[StringComparison]::OrdinalIgnoreCase)-or$left.Equals($right+':Zone.Identifier:$DATA',[StringComparison]::OrdinalIgnoreCase)}
    return $left.Equals($right,[StringComparison]::OrdinalIgnoreCase)
}

function Test-CcodReleaseAuthorityStreams {
    param($Identity,[switch]$Directory,[switch]$AllowZone)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($name in @($Identity.Streams)){
        if($name-isnot[string]-or-not$seen.Add([string]$name)){return $false}
        if($Directory){if($name-cnotin@('::$DATA','::$INDEX_ALLOCATION')){return $false}}
        elseif($name-cne'::$DATA'-and(-not$AllowZone-or$name-cne':Zone.Identifier:$DATA')){return $false}
    }
    if($Directory){return $seen.Contains('::$DATA')-or$seen.Contains('::$INDEX_ALLOCATION')};return $seen.Contains('::$DATA')
}

function Get-CcodReleaseAuthorityStreamSha256 {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)
    $position=$Stream.Position;$sha=[Security.Cryptography.SHA256]::Create()
    try{$Stream.Position=0;return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','').ToLowerInvariant()}finally{$Stream.Position=$position;$sha.Dispose()}
}

function Get-CcodReleaseAuthorityStreamBytes {
    param([Parameter(Mandatory)][IO.FileStream]$Stream,[Parameter(Mandatory)][long]$MaximumBytes)
    if($Stream.Length-lt1-or$Stream.Length-gt$MaximumBytes){throw 'release file length'}
    $position=$Stream.Position
    try{$Stream.Position=0;$bytes=[byte[]]::new([int]$Stream.Length);$offset=0;while($offset-lt$bytes.Length){$read=$Stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-le0){throw 'release file truncated'};$offset+=$read};return ,$bytes}finally{$Stream.Position=$position}
}

function Open-CcodReleaseDirectoryAuthority {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId,[switch]$AllowChildMutation)
    $handle=$null
    try{
        $full=Assert-CcodReleaseContractPlainPath -Path $Path -Directory $true -ErrorId $ErrorId
        $handle=[CcodReleaseFileAuthorityV1]::OpenDirectory($full,[bool]$AllowChildMutation);$identity=[CcodReleaseFileAuthorityV1]::Identity($handle)
        if(-not[CcodReleaseFileAuthorityV1]::IsDirectory($identity)-or[CcodReleaseFileAuthorityV1]::IsReparse($identity)-or-not(Test-CcodReleaseAuthorityFinalPath $identity.FinalPath $full)-or-not(Test-CcodReleaseAuthorityStreams $identity -Directory)){throw ('directory identity attrs='+$identity.Attributes+' final='+$identity.FinalPath+' expected='+$full+' streams='+(@($identity.Streams)-join'|'))}
        $children=[CcodReleaseFileAuthorityV1]::EnumerateDirectory($handle)
        $result=[pscustomobject]@{Kind='Directory';Path=$full;Handle=$handle;Identity=$identity;Children=[string[]]$children;Closed=$false};$handle=$null;return $result
    }catch{if($null-ne$handle){$handle.Dispose()};Throw-CcodReleaseContractError $ErrorId 'Release directory authority is unsafe or changed.' $Path}
}

function Open-CcodReleaseFileAuthority {
    param([Parameter(Mandatory)]$Directory,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)][string]$ErrorId,[long]$MaximumBytes=536870912,[switch]$AllowZone,[switch]$ShareDelete)
    $stream=$null
    try{
        if($null-eq$Directory-or$Directory.Closed-or$Directory.Kind-cne'Directory'-or$Leaf-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}\z'-or$Leaf.EndsWith('.')-or$Leaf.EndsWith(' ')){throw 'file leaf'}
        [void](Assert-CcodReleaseAuthorityCurrent -Authority $Directory -ErrorId $ErrorId)
        $path=Join-Path $Directory.Path $Leaf;$full=Assert-CcodReleaseContractPlainPath -Path $path -Directory $false -ErrorId $ErrorId
        $stream=[CcodReleaseFileAuthorityV1]::OpenReadFile($full,[bool]$ShareDelete);$identity=[CcodReleaseFileAuthorityV1]::Identity($stream.SafeFileHandle)
        if([CcodReleaseFileAuthorityV1]::IsDirectory($identity)-or[CcodReleaseFileAuthorityV1]::IsReparse($identity)-or$identity.Links-ne1-or$identity.Volume-ne$Directory.Identity.Volume-or-not(Test-CcodReleaseAuthorityFinalPath $identity.FinalPath $full)-or-not(Test-CcodReleaseAuthorityStreams $identity -AllowZone:$AllowZone)-or$stream.Length-lt1-or$stream.Length-gt$MaximumBytes){throw 'file identity'}
        $sha=Get-CcodReleaseAuthorityStreamSha256 $stream;$result=[pscustomobject]@{Kind='File';Path=$full;Leaf=$Leaf;Stream=$stream;Identity=$identity;Length=[long]$stream.Length;Sha256=$sha;AllowZone=[bool]$AllowZone;Closed=$false};$stream=$null;return $result
    }catch{if($null-ne$stream){$stream.Dispose()};Throw-CcodReleaseContractError $ErrorId 'Release file authority is unsafe or changed.' $Leaf}
}

function Open-CcodReleaseZoneAuthority {
    param([Parameter(Mandatory)]$File,[Parameter(Mandatory)][string]$ErrorId)
    $stream=$null
    try{
        [void](Assert-CcodReleaseAuthorityCurrent -Authority $File -ErrorId $ErrorId)
        $stream=[CcodReleaseFileAuthorityV1]::OpenReadFile($File.Path+':Zone.Identifier',$false);$identity=[CcodReleaseFileAuthorityV1]::Identity($stream.SafeFileHandle)
        if([CcodReleaseFileAuthorityV1]::IsDirectory($identity)-or[CcodReleaseFileAuthorityV1]::IsReparse($identity)-or$identity.Links-ne1-or$identity.Volume-ne$File.Identity.Volume-or$identity.FileId-ne$File.Identity.FileId-or-not(Test-CcodReleaseAuthorityFinalPath $identity.FinalPath $File.Path -Zone)-or$stream.Length-lt1-or$stream.Length-gt65536){throw 'zone identity'}
        $sha=Get-CcodReleaseAuthorityStreamSha256 $stream;$result=[pscustomobject]@{Kind='Zone';Path=$File.Path;Stream=$stream;Identity=$identity;Length=[long]$stream.Length;Sha256=$sha;Closed=$false};$stream=$null;return $result
    }catch{if($null-ne$stream){$stream.Dispose()};Throw-CcodReleaseContractError $ErrorId 'Release Zone authority is missing, unsafe, or changed.' $File.Path}
}

function Assert-CcodReleaseAuthorityCurrent {
    param([Parameter(Mandatory)]$Authority,[Parameter(Mandatory)][string]$ErrorId,[switch]$CheckBytes)
    try{
        if($null-eq$Authority-or$Authority.Closed){throw 'closed authority'}
        $handle=if($Authority.Kind-ceq'Directory'){$Authority.Handle}else{$Authority.Stream.SafeFileHandle};$current=[CcodReleaseFileAuthorityV1]::Identity($handle);$expected=$Authority.Identity
        if($current.Volume-ne$expected.Volume-or$current.FileId-ne$expected.FileId-or$current.Links-ne$expected.Links-or$current.Attributes-ne$expected.Attributes){throw 'identity drift'}
        if($Authority.Kind-ceq'Directory'){
            if(-not(Test-CcodReleaseAuthorityFinalPath $current.FinalPath $Authority.Path)-or-not(Test-CcodReleaseAuthorityStreams $current -Directory)){throw 'directory drift'}
            $children=[CcodReleaseFileAuthorityV1]::EnumerateDirectory($Authority.Handle);if(($children-join"`0")-cne(@($Authority.Children)-join"`0")){throw 'membership drift'}
        }elseif($Authority.Kind-ceq'Zone'){
            if(-not(Test-CcodReleaseAuthorityFinalPath $current.FinalPath $Authority.Path -Zone)-or$Authority.Stream.Length-ne$Authority.Length){throw 'zone drift'}
        }else{
            if(-not(Test-CcodReleaseAuthorityFinalPath $current.FinalPath $Authority.Path)-or-not(Test-CcodReleaseAuthorityStreams $current -AllowZone:$Authority.AllowZone)-or$Authority.Stream.Length-ne$Authority.Length){throw 'file drift'}
        }
        if($CheckBytes-and(Get-CcodReleaseAuthorityStreamSha256 $Authority.Stream)-cne$Authority.Sha256){throw 'byte drift'}
        return $true
    }catch{Throw-CcodReleaseContractError $ErrorId 'Held release authority changed or closed.' $Authority.Path}
}

function Close-CcodReleaseAuthority {
    param($Authority)
    if($null-eq$Authority-or$Authority.Closed){return};try{if($Authority.Kind-ceq'Directory'){$Authority.Handle.Dispose()}else{$Authority.Stream.Dispose()}}finally{$Authority.Closed=$true}
}

function Publish-CcodReleaseReceiptAuthority {
    param([Parameter(Mandatory)]$Directory,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][string]$ErrorId)
    $stream=$null;$temporary=$null;$target=$null;$committed=$false
    try{
        [void](Assert-CcodReleaseAuthorityCurrent -Authority $Directory -ErrorId $ErrorId)
        if($Leaf-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}\.json\z'-or$Bytes.Length-lt1-or$Bytes.Length-gt65536){throw 'receipt input'}
        $target=Join-Path $Directory.Path $Leaf;if([IO.File]::Exists($target)-or[IO.Directory]::Exists($target)){throw 'receipt exists'}
        $temporaryLeaf='.ccod-defender-receipt-'+[guid]::NewGuid().ToString('N')+'.tmp';$temporary=Join-Path $Directory.Path $temporaryLeaf;$stream=[CcodReleaseFileAuthorityV1]::CreateReceiptFileRelative($Directory.Handle,$temporaryLeaf);$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)
        $before=[CcodReleaseFileAuthorityV1]::Identity($stream.SafeFileHandle);if([CcodReleaseFileAuthorityV1]::IsDirectory($before)-or[CcodReleaseFileAuthorityV1]::IsReparse($before)-or$before.Links-ne1-or-not(Test-CcodReleaseAuthorityFinalPath $before.FinalPath $temporary)-or-not(Test-CcodReleaseAuthorityStreams $before)){throw 'temporary identity'}
        $move=[CcodReleaseFileAuthorityV1]::MoveNoReplaceRelative($stream.SafeFileHandle,$Directory.Handle,$Leaf);if($move-ne0){throw "receipt rename $move"};$committed=$true
        $after=[CcodReleaseFileAuthorityV1]::Identity($stream.SafeFileHandle);if($after.Volume-ne$before.Volume-or$after.FileId-ne$before.FileId-or-not(Test-CcodReleaseAuthorityFinalPath $after.FinalPath $target)){throw 'receipt publish identity'}
        $sha=Get-CcodReleaseAuthorityStreamSha256 $stream;$result=[pscustomobject]@{Kind='File';Path=$target;Leaf=$Leaf;Stream=$stream;Identity=$after;Length=[long]$stream.Length;Sha256=$sha;AllowZone=$false;Closed=$false};$stream=$null;return $result
    }catch{
        $detail=$_.Exception.Message
        $cleanupFailed=$false
        if($null-ne$stream){
            try{if([CcodReleaseFileAuthorityV1]::Delete($stream.SafeFileHandle)-ne0){$cleanupFailed=$true}}catch{$cleanupFailed=$true}
            try{$stream.Dispose()}catch{$cleanupFailed=$true}
        }
        if($committed-and$null-ne$target-and($cleanupFailed-or[IO.File]::Exists($target)-or[IO.Directory]::Exists($target))){$detail+='; committed receipt cleanup could not be proven'}
        Throw-CcodReleaseContractError $ErrorId ('Defender receipt could not be durably published: '+$detail) $Leaf
    }
}

function Get-CcodExpectedReleaseAssetNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$Version)
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

function Open-CcodExactReleaseAssetAuthority {
    param([Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$ErrorId)
    $directory=$null;$files=[Collections.Generic.List[object]]::new()
    try{
        $names=@(Get-CcodExpectedReleaseAssetNames -Version $Version);$directory=Open-CcodReleaseDirectoryAuthority -Path $AssetDirectory -ErrorId $ErrorId;$expectedSorted=[string[]]@($names);[Array]::Sort($expectedSorted,[StringComparer]::Ordinal)
        if($directory.Children.Count-ne$names.Count-or($directory.Children-join"`0")-cne($expectedSorted-join"`0")){throw ('exact asset membership actual='+($directory.Children-join'|')+' expected='+($expectedSorted-join'|'))}
        for($index=0;$index-lt$names.Count;$index++){$files.Add((Open-CcodReleaseFileAuthority -Directory $directory -Leaf $names[$index] -ErrorId $ErrorId -AllowZone:($index-in@(0,5))))}
        return [pscustomobject]@{Directory=$directory;Files=@($files);Names=$names;Closed=$false}
    }catch{foreach($file in @($files)){Close-CcodReleaseAuthority $file};Close-CcodReleaseAuthority $directory;Throw-CcodReleaseContractError $ErrorId 'Exact release asset authority could not be pinned.' $AssetDirectory}
}

function Assert-CcodExactReleaseAssetAuthorityCurrent {
    param([Parameter(Mandatory)]$Authority,[Parameter(Mandatory)][string]$ErrorId)
    if($Authority.Closed){Throw-CcodReleaseContractError $ErrorId 'Exact release asset authority is closed.' $Authority.Directory.Path};Assert-CcodReleaseAuthorityCurrent $Authority.Directory $ErrorId|Out-Null;foreach($file in @($Authority.Files)){Assert-CcodReleaseAuthorityCurrent $file $ErrorId -CheckBytes|Out-Null};return $true
}

function Close-CcodExactReleaseAssetAuthority {
    param($Authority)
    if($null-eq$Authority-or$Authority.Closed){return};for($index=$Authority.Files.Count-1;$index-ge0;$index--){Close-CcodReleaseAuthority $Authority.Files[$index]};Close-CcodReleaseAuthority $Authority.Directory;$Authority.Closed=$true
}

function Test-CcodReleaseContractCanonicalUtc {
    param($Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodReleaseContractJsonInteger {
    param($Value,[long]$Minimum=0)
    return ($Value-is[int]-or$Value-is[long])-and[decimal]$Value-eq[decimal][long]$Value-and[long]$Value-ge$Minimum
}

function Assert-CcodReleaseContractPlainPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Directory,
        [Parameter(Mandatory)][string]$ErrorId
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path.IndexOf(':',$Path.IndexOf(':') + 1) -ge 0) { throw 'path' }
        $canonical = [IO.Path]::GetFullPath($Path)
        $pathRoot = [IO.Path]::GetPathRoot($canonical)
        $full = if ($canonical.Length -gt $pathRoot.Length) { $canonical.TrimEnd('\') } else { $canonical }
        $presented = if ($Path.Length -gt $pathRoot.Length) { $Path.TrimEnd('\') } else { $Path }
        if ($full -cne $presented) { throw 'canonical' }
        if ($Directory) {
            if (-not [IO.Directory]::Exists($full) -or [IO.File]::Exists($full)) { throw 'directory' }
        } else {
            if (-not [IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { throw 'file' }
        }
        $current = $full
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse' }
            if ($current.TrimEnd('\') -ceq $pathRoot.TrimEnd('\')) { break }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $next = if ($parent.FullName.Length -gt $pathRoot.Length) { $parent.FullName.TrimEnd('\') } else { $parent.FullName }
            if ($next -ceq $current) { break }
            $current = $next
        }
        return $full
    } catch {
        Throw-CcodReleaseContractError $ErrorId 'Release contract path is missing, noncanonical, or has unsafe ancestry.' $Path
    }
}

function Get-CcodReleaseContractHash {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Skip-CcodReleaseContractJsonWhitespace {
    param([string]$Json,[int]$Offset)
    $index = $Offset
    while ($index -lt $Json.Length -and [char]::IsWhiteSpace($Json[$index])) { $index++ }
    return $index
}

function Read-CcodReleaseContractJsonStringToken {
    param([string]$Json,[int]$Offset)
    if ($Offset -ge $Json.Length -or $Json[$Offset] -ne [char]34) { throw 'json string' }
    $index = $Offset + 1
    while ($index -lt $Json.Length) {
        $character = $Json[$index]
        if ($character -eq [char]34) {
            $end = $index + 1
            $raw = $Json.Substring($Offset,$end-$Offset)
            $decoded = ConvertFrom-CcodReleaseContractJson -Json $raw
            if ($decoded -isnot [string]) { throw 'json string type' }
            return [pscustomobject]@{Value=$decoded;End=$end}
        }
        if ([int][char]$character -lt 32) { throw 'json control' }
        if ($character -eq [char]92) {
            $index++
            if ($index -ge $Json.Length) { throw 'json escape' }
            $escape = $Json[$index]
            if ($escape -eq [char]117) {
                if (($index+4) -ge $Json.Length -or $Json.Substring($index+1,4) -cnotmatch '^[0-9a-fA-F]{4}\z') { throw 'json unicode escape' }
                $index += 5
                continue
            }
            if ('"\/bfnrt'.IndexOf($escape) -lt 0) { throw 'json escape' }
        }
        $index++
    }
    throw 'json string end'
}

function Read-CcodReleaseContractJsonValue {
    param([string]$Json,[int]$Offset,[int]$Depth=0)
    if ($Depth -gt 64) { throw 'json depth' }
    $index = Skip-CcodReleaseContractJsonWhitespace $Json $Offset
    if ($index -ge $Json.Length) { throw 'json value' }
    $character = $Json[$index]
    if ($character -eq [char]34) { return [int](Read-CcodReleaseContractJsonStringToken $Json $index).End }
    if ($character -eq [char]123) {
        $index++
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
        if ($index -lt $Json.Length -and $Json[$index] -eq [char]125) { return $index+1 }
        while ($true) {
            $key = Read-CcodReleaseContractJsonStringToken $Json $index
            if (-not $keys.Add([string]$key.Value)) { throw 'duplicate json property' }
            $index = Skip-CcodReleaseContractJsonWhitespace $Json ([int]$key.End)
            if ($index -ge $Json.Length -or $Json[$index] -ne [char]58) { throw 'json colon' }
            $index = Read-CcodReleaseContractJsonValue $Json ($index+1) ($Depth+1)
            $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
            if ($index -ge $Json.Length) { throw 'json object end' }
            if ($Json[$index] -eq [char]125) { return $index+1 }
            if ($Json[$index] -ne [char]44) { throw 'json comma' }
            $index = Skip-CcodReleaseContractJsonWhitespace $Json ($index+1)
        }
    }
    if ($character -eq [char]91) {
        $index++
        $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
        if ($index -lt $Json.Length -and $Json[$index] -eq [char]93) { return $index+1 }
        while ($true) {
            $index = Read-CcodReleaseContractJsonValue $Json $index ($Depth+1)
            $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
            if ($index -ge $Json.Length) { throw 'json array end' }
            if ($Json[$index] -eq [char]93) { return $index+1 }
            if ($Json[$index] -ne [char]44) { throw 'json comma' }
            $index = Skip-CcodReleaseContractJsonWhitespace $Json ($index+1)
        }
    }
    $match = [regex]::Match($Json.Substring($index),'^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)')
    if (-not $match.Success) { throw 'json primitive' }
    return $index + $match.Length
}

function Assert-CcodReleaseContractJsonLexicalShape {
    param([string]$Json)
    $end = Read-CcodReleaseContractJsonValue $Json 0 0
    $end = Skip-CcodReleaseContractJsonWhitespace $Json $end
    if ($end -ne $Json.Length) { throw 'json trailing data' }
}

function Read-CcodReleaseContractJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId,[int64]$MaximumBytes=4194304)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) { throw 'length' }
        $raw = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
        Assert-CcodReleaseContractJsonLexicalShape -Json $raw
        $value = ConvertFrom-CcodReleaseContractJson -Json $raw
        if ($null -eq $value -or $value -isnot [pscustomobject]) { throw 'shape' }
        return [pscustomobject]@{ Raw=$raw; Value=$value }
    } catch {
        Throw-CcodReleaseContractError $ErrorId 'Release contract JSON is malformed or outside its size bound.' $Path
    }
}

function Read-CcodReleaseContractPinnedJson {
    param([Parameter(Mandatory)]$Authority,[Parameter(Mandatory)][string]$ErrorId,[int64]$MaximumBytes=4194304)
    try{
        Assert-CcodReleaseAuthorityCurrent $Authority $ErrorId -CheckBytes|Out-Null;$bytes=Get-CcodReleaseAuthorityStreamBytes $Authority.Stream $MaximumBytes;$raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);Assert-CcodReleaseContractJsonLexicalShape $raw;$value=ConvertFrom-CcodReleaseContractJson -Json $raw;if($value-isnot[pscustomobject]){throw 'json shape'};Assert-CcodReleaseAuthorityCurrent $Authority $ErrorId -CheckBytes|Out-Null;return [pscustomobject]@{Raw=$raw;Value=$value;Bytes=$bytes}
    }catch{Throw-CcodReleaseContractError $ErrorId 'Pinned release JSON is malformed, changed, or outside its bound.' $Authority.Path}
}

function Get-CcodReleaseContractStreamHash {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Test-CcodReleaseContractTrayProvenance {
    param([string]$Path,[string]$Version,[string]$GitCommit,[string]$Timestamp,[string]$ErrorId)
    $record=(Read-CcodReleaseContractJson -Path $Path -ErrorId $ErrorId).Value
    $top='schemaVersion,product,version,gitCommit,buildTimestampUtc,targetFramework,compiler,referenceRoot,sourceFiles,iconSha256,manifestSha256,configSha256,artifactSha256,configArtifactSha256'
    if((@($record.PSObject.Properties.Name)-join',')-cne$top-or-not(Test-CcodReleaseContractJsonInteger $record.schemaVersion 1)-or[long]$record.schemaVersion-ne1-or$record.product-isnot[string]-or$record.product-cne'CodexRemote-fix'-or$record.version-isnot[string]-or$record.version-cne$Version-or$record.gitCommit-isnot[string]-or$record.gitCommit-cne$GitCommit-or$record.buildTimestampUtc-isnot[string]-or$record.buildTimestampUtc-cne$Timestamp-or-not(Test-CcodReleaseContractCanonicalUtc $record.buildTimestampUtc)-or$record.targetFramework-isnot[string]-or$record.targetFramework-cne'net48'-or$record.referenceRoot-isnot[string]-or$record.referenceRoot-cne'locked-net48'-or
       $record.compiler-isnot[pscustomobject]-or(@($record.compiler.PSObject.Properties.Name)-join',')-cne'name,sha256'-or$record.compiler.name-isnot[string]-or$record.compiler.name-cne'csc.exe'-or$record.compiler.sha256-isnot[string]-or$record.compiler.sha256-cnotmatch'^[0-9a-f]{64}\z'){
        Throw-CcodReleaseContractError $ErrorId 'TrayHost provenance schema or common identity is invalid.' $Path
    }
    $previous=$null;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($source in @($record.sourceFiles)){
        if($source-isnot[pscustomobject]-or(@($source.PSObject.Properties.Name)-join',')-cne'name,sha256'-or$source.name-isnot[string]-or$source.name-cnotmatch'^[A-Za-z0-9._-]{1,128}\z'-or$source.sha256-isnot[string]-or$source.sha256-cnotmatch'^[0-9a-f]{64}\z'-or-not$seen.Add([string]$source.name)-or($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,[string]$source.name)-ge0)){Throw-CcodReleaseContractError $ErrorId 'TrayHost provenance source records are malformed, duplicate, or unordered.' $Path};$previous=[string]$source.name
    }
    if($seen.Count-eq0){Throw-CcodReleaseContractError $ErrorId 'TrayHost provenance source records are empty.' $Path}
    foreach($field in @('iconSha256','manifestSha256','configSha256','artifactSha256','configArtifactSha256')){if($record.$field-isnot[string]-or$record.$field-cnotmatch'^[0-9a-f]{64}\z'){Throw-CcodReleaseContractError $ErrorId 'TrayHost provenance hashes are malformed.' $Path}}
    return $record
}

function Test-CcodReleaseContractInventory {
    param([string]$Path,[string]$ErrorId)
    try{$text=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true));if($text.Length-lt70-or$text.Length-gt1048576){throw 'inventory bounds'};$lines=@($text-split'\r?\n');while($lines.Count-gt0-and$lines[-1]-ceq''){$lines=$lines[0..($lines.Count-2)]};if($lines.Count-lt3-or$lines[0]-cne'procedure AddCcodExpectedSetupDirectories(Directories: TStrings);'-or$lines[1]-cne'begin'-or$lines[-1]-cne'end;'){throw 'inventory frame'};$previous=$null;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);for($index=2;$index-lt$lines.Count-1;$index++){if($lines[$index]-cnotmatch"^  Directories\.Add\('(?<path>[A-Za-z0-9._-]+(?:\\[A-Za-z0-9._-]+)*)'\);\z"){throw 'inventory line'};$value=[string]$Matches.path;if(-not$seen.Add($value)-or($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,$value)-ge0)){throw 'inventory order'};$previous=$value};return $text}catch{Throw-CcodReleaseContractError $ErrorId 'Setup destination inventory is not the exact generated grammar.' $Path}
}

function Test-CcodReleasePortableManifestDeep {
    param($Manifest,[string]$ManifestRaw,[string]$ManifestPath,[string]$Directory,[string]$Version,[string]$ErrorId)
    $names=@(Get-CcodExpectedReleaseAssetNames -Version $Version);$expected=@($names[0],$names[1],$names[2],$names[3],'CodexRemote-fix.exe','CodexRemote-fix.exe.config')
    if((@($Manifest.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,buildTimestampUtc,distribution,assets'-or-not(Test-CcodReleaseContractJsonInteger $Manifest.schemaVersion 2)-or[long]$Manifest.schemaVersion-ne2-or$Manifest.product-isnot[string]-or$Manifest.product-cne'CodexRemote-fix'-or$Manifest.version-isnot[string]-or$Manifest.version-cne$Version-or$Manifest.gitCommit-isnot[string]-or$Manifest.gitCommit-cnotmatch'^[0-9a-f]{40}\z'-or-not(Test-CcodReleaseContractCanonicalUtc $Manifest.buildTimestampUtc)-or$Manifest.distribution-isnot[string]-or$Manifest.distribution-cne'portable-zip'){Throw-CcodReleaseContractError $ErrorId 'Portable release manifest metadata is invalid.' $ManifestPath}
    $map=Get-CcodReleaseContractManifestMap -Manifest $Manifest -ExpectedNames $expected -ErrorId $ErrorId -Target $ManifestPath
    foreach($name in $expected[0..3]){if((Get-CcodReleaseContractHash (Join-Path $Directory $name))-cne$map[$name]){Throw-CcodReleaseContractError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable public asset hash mismatch.' $name}}
    $checksum=[IO.File]::ReadAllText((Join-Path $Directory $names[1]),[Text.UTF8Encoding]::new($false,$true)).TrimEnd("`r","`n");if($checksum-cne("$($map[$names[0]]) *$($names[0])")){Throw-CcodReleaseContractError $ErrorId 'Portable checksum is invalid.' $names[1]}
    [void](Test-CcodReleaseContractTrayProvenance -Path (Join-Path $Directory $names[2]) -Version $Version -GitCommit $Manifest.gitCommit -Timestamp $Manifest.buildTimestampUtc -ErrorId $ErrorId)
    $payloadPath=Join-Path $Directory $names[3];$payload=(Read-CcodReleaseContractJson -Path $payloadPath -ErrorId $ErrorId).Value
    if((@($payload.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,buildTimestampUtc,files'-or-not(Test-CcodReleaseContractJsonInteger $payload.schemaVersion 1)-or[long]$payload.schemaVersion-ne1-or$payload.product-isnot[string]-or$payload.product-cne'CodexRemote-fix'-or$payload.version-isnot[string]-or$payload.version-cne$Version-or$payload.gitCommit-isnot[string]-or$payload.gitCommit-cne$Manifest.gitCommit-or$payload.buildTimestampUtc-isnot[string]-or$payload.buildTimestampUtc-cne$Manifest.buildTimestampUtc){Throw-CcodReleaseContractError $ErrorId 'Portable payload manifest metadata is invalid.' $payloadPath}
    $fileRecords=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$previous=$null
    foreach($record in @($payload.files)){if($record-isnot[pscustomobject]-or(@($record.PSObject.Properties.Name)-join',')-cne'path,length,sha256'-or$record.path-isnot[string]-or$record.path-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\z'-or$record.path.Contains('//')-or$record.path.Contains(':')-or$record.path-match'(^|/)\.\.?(?:/|$)'-or($record.length-isnot[int]-and$record.length-isnot[long])-or[long]$record.length-lt0-or$record.sha256-isnot[string]-or$record.sha256-cnotmatch'^[0-9a-f]{64}\z'-or$fileRecords.ContainsKey([string]$record.path)-or($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,[string]$record.path)-ge0)){Throw-CcodReleaseContractError $ErrorId 'Portable payload records are malformed, duplicate, or unordered.' $payloadPath};$fileRecords.Add([string]$record.path,$record);$previous=[string]$record.path}
    if($fileRecords.Count-eq0){Throw-CcodReleaseContractError $ErrorId 'Portable payload manifest is empty.' $payloadPath}
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop;$archive=$null
    try{
        $archive=[IO.Compression.ZipFile]::OpenRead((Join-Path $Directory $names[0]));$zip=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($entry in @($archive.Entries)){$name=([string]$entry.FullName).Replace('\','/');if($name.EndsWith('/')){if($name-cne'payload/'-and-not$name.StartsWith('payload/',[StringComparison]::Ordinal)){throw 'unexpected directory'};continue};if($name-isnot[string]-or$name-cmatch'(^|/)\.\.?(?:/|$)|:'-or$zip.ContainsKey($name)){throw 'zip entry'};$zip.Add($name,$entry)}
        $expectedZip=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($root in @('CodexRemote-fix.exe','CodexRemote-fix.exe.config','Install-CodexRemote-fix.ps1','payload-manifest.json')){[void]$expectedZip.Add($root)};foreach($path in $fileRecords.Keys){[void]$expectedZip.Add('payload/'+$path)}
        if($zip.Count-ne$expectedZip.Count-or@($zip.Keys|Where-Object{-not$expectedZip.Contains($_)}).Count-ne0){throw 'zip membership'}
        $entry=$zip['payload-manifest.json'];$stream=$entry.Open();try{if((Get-CcodReleaseContractStreamHash $stream)-cne(Get-CcodReleaseContractHash $payloadPath)){throw 'embedded manifest'}}finally{$stream.Dispose()}
        foreach($root in @('CodexRemote-fix.exe','CodexRemote-fix.exe.config')){$stream=$zip[$root].Open();try{if((Get-CcodReleaseContractStreamHash $stream)-cne$map[$root]){throw 'root launcher'}}finally{$stream.Dispose()}}
        foreach($path in $fileRecords.Keys){$record=$fileRecords[$path];$entry=$zip['payload/'+$path];if([long]$entry.Length-ne[long]$record.length){throw 'payload length'};$stream=$entry.Open();try{if((Get-CcodReleaseContractStreamHash $stream)-cne$record.sha256){throw 'payload hash'}}finally{$stream.Dispose()}}
    }catch{Throw-CcodReleaseContractError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable ZIP does not match its deep payload contract.' $names[0]}finally{if($null-ne$archive){$archive.Dispose()}}
    return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=[string]$Manifest.gitCommit;BuildTimestampUtc=[string]$Manifest.buildTimestampUtc;InstallerSha256=[string]$map[$names[0]];InstallerName=$names[0];Distribution='portable-zip'}
}

function Test-CcodReleaseSetupManifestDeep {
    param($Manifest,[string]$ManifestPath,[string]$Directory,[string]$Version,[string]$ErrorId)
    $names=@(Get-CcodExpectedReleaseAssetNames -Version $Version);$expected=@($names[5],$names[6],$names[2],$names[7],$names[8],$names[9])
    if((@($Manifest.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,buildTimestampUtc,assets'-or-not(Test-CcodReleaseContractJsonInteger $Manifest.schemaVersion 1)-or[long]$Manifest.schemaVersion-ne1-or$Manifest.product-isnot[string]-or$Manifest.product-cne'CodexRemote-fix'-or$Manifest.version-isnot[string]-or$Manifest.version-cne$Version-or$Manifest.gitCommit-isnot[string]-or$Manifest.gitCommit-cnotmatch'^[0-9a-f]{40}\z'-or-not(Test-CcodReleaseContractCanonicalUtc $Manifest.buildTimestampUtc)){Throw-CcodReleaseContractError $ErrorId 'Setup release manifest metadata is invalid.' $ManifestPath}
    $map=Get-CcodReleaseContractManifestMap -Manifest $Manifest -ExpectedNames $expected -ErrorId $ErrorId -Target $ManifestPath;foreach($name in $expected){if((Get-CcodReleaseContractHash (Join-Path $Directory $name))-cne$map[$name]){Throw-CcodReleaseContractError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Setup public asset hash mismatch.' $name}}
    $checksum=[IO.File]::ReadAllText((Join-Path $Directory $names[6]),[Text.UTF8Encoding]::new($false,$true)).TrimEnd("`r","`n");if($checksum-cne("$($map[$names[5]]) *$($names[5])")){Throw-CcodReleaseContractError $ErrorId 'Setup checksum is invalid.' $names[6]}
    [void](Test-CcodReleaseContractTrayProvenance -Path (Join-Path $Directory $names[2]) -Version $Version -GitCommit $Manifest.gitCommit -Timestamp $Manifest.buildTimestampUtc -ErrorId $ErrorId)
    $packageManifestPath=Join-Path $Directory $names[8];$package=(Read-CcodReleaseContractJson -Path $packageManifestPath -ErrorId $ErrorId).Value
    if((@($package.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,payloadManifest,files'-or-not(Test-CcodReleaseContractJsonInteger $package.schemaVersion 1)-or[long]$package.schemaVersion-ne1-or$package.product-isnot[string]-or$package.product-cne'CodexRemote-fix'-or$package.version-isnot[string]-or$package.version-cne$Version-or$package.gitCommit-isnot[string]-or$package.gitCommit-cne$Manifest.gitCommit-or$package.payloadManifest-isnot[pscustomobject]-or(@($package.payloadManifest.PSObject.Properties.Name)-join',')-cne'name,length,sha256'-or$package.payloadManifest.name-isnot[string]-or$package.payloadManifest.name-cne'installer-payload.manifest.json'-or($package.payloadManifest.length-isnot[int]-and$package.payloadManifest.length-isnot[long])-or[long]$package.payloadManifest.length-lt1-or$package.payloadManifest.sha256-isnot[string]-or$package.payloadManifest.sha256-cnotmatch'^[0-9a-f]{64}\z'){Throw-CcodReleaseContractError $ErrorId 'Setup package manifest nested payload binding is invalid.' $packageManifestPath}
    $previous=$null;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($file in @($package.files)){if($file-isnot[pscustomobject]-or(@($file.PSObject.Properties.Name)-join',')-cne'path,length,sha256'-or$file.path-isnot[string]-or$file.path-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\z'-or$file.path-cmatch'(^|/)\.\.?(?:/|$)|:'-or($file.length-isnot[int]-and$file.length-isnot[long])-or[long]$file.length-lt0-or$file.sha256-isnot[string]-or$file.sha256-cnotmatch'^[0-9a-f]{64}\z'-or-not$seen.Add([string]$file.path)-or($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,[string]$file.path)-ge0)){Throw-CcodReleaseContractError $ErrorId 'Setup package manifest files are malformed, duplicate, or unordered.' $packageManifestPath};$previous=[string]$file.path};if($seen.Count-eq0){Throw-CcodReleaseContractError $ErrorId 'Setup package manifest files are empty.' $packageManifestPath}
    $provenancePath=Join-Path $Directory $names[7];$provenance=(Read-CcodReleaseContractJson -Path $provenancePath -ErrorId $ErrorId).Value;$top='schemaVersion,product,version,gitCommit,buildTimestampUtc,installerPackage,installerPackageManifest,activationBootstrap,buildInputs,peContract'
    $artifactFields='name,length,sha256';$manifestFields='name,length,sha256,fileCount,payloadManifestSha256';$buildFields='innoTemplateSha256,destinationInventorySha256,compilerSha256,compilerFileVersion';$peFields='fileVersion,packageManifestFirst,packageManifestLast,bootstrapFirst,bootstrapLast,companyName,legalCopyright'
    if((@($provenance.PSObject.Properties.Name)-join',')-cne$top-or-not(Test-CcodReleaseContractJsonInteger $provenance.schemaVersion 2)-or[long]$provenance.schemaVersion-ne2-or$provenance.product-isnot[string]-or$provenance.product-cne'CodexRemote-fix'-or$provenance.version-isnot[string]-or$provenance.version-cne$Version-or$provenance.gitCommit-isnot[string]-or$provenance.gitCommit-cne$Manifest.gitCommit-or$provenance.buildTimestampUtc-isnot[string]-or$provenance.buildTimestampUtc-cne$Manifest.buildTimestampUtc-or
       (@($provenance.installerPackage.PSObject.Properties.Name)-join',')-cne$artifactFields-or(@($provenance.installerPackageManifest.PSObject.Properties.Name)-join',')-cne$manifestFields-or(@($provenance.activationBootstrap.PSObject.Properties.Name)-join',')-cne$artifactFields-or(@($provenance.buildInputs.PSObject.Properties.Name)-join',')-cne$buildFields-or(@($provenance.peContract.PSObject.Properties.Name)-join',')-cne$peFields){Throw-CcodReleaseContractError $ErrorId 'Setup provenance nested property schema is invalid.' $provenancePath}
    foreach($artifact in @($provenance.installerPackage,$provenance.installerPackageManifest,$provenance.activationBootstrap)){
        if($artifact.name-isnot[string]-or$artifact.length-isnot[int]-and$artifact.length-isnot[long]-or$artifact.sha256-isnot[string]){Throw-CcodReleaseContractError $ErrorId 'Setup provenance artifact scalar types are invalid.' $provenancePath}
    }
    if($provenance.installerPackageManifest.fileCount-isnot[int]-and$provenance.installerPackageManifest.fileCount-isnot[long]-or$provenance.installerPackageManifest.payloadManifestSha256-isnot[string]){Throw-CcodReleaseContractError $ErrorId 'Setup provenance manifest scalar types are invalid.' $provenancePath}
    foreach($name in @('innoTemplateSha256','destinationInventorySha256','compilerSha256')){if($provenance.buildInputs.$name-isnot[string]){Throw-CcodReleaseContractError $ErrorId 'Setup provenance build hash type is invalid.' $provenancePath}}
    foreach($name in @('compilerFileVersion')){if($provenance.buildInputs.$name-isnot[string]){Throw-CcodReleaseContractError $ErrorId 'Setup provenance build version type is invalid.' $provenancePath}}
    foreach($name in @('fileVersion','packageManifestFirst','packageManifestLast','bootstrapFirst','bootstrapLast','companyName','legalCopyright')){if($provenance.peContract.$name-isnot[string]){Throw-CcodReleaseContractError $ErrorId 'Setup provenance PE scalar type is invalid.' $provenancePath}}
    $packageManifestHash=Get-CcodReleaseContractHash $packageManifestPath;$inventoryPath=Join-Path $Directory $names[9];[void](Test-CcodReleaseContractInventory $inventoryPath $ErrorId)
    if($provenance.installerPackage.name-cne'installer-package.zip'-or$provenance.installerPackage.length-isnot[long]-and$provenance.installerPackage.length-isnot[int]-or[long]$provenance.installerPackage.length-lt1-or$provenance.installerPackage.sha256-cnotmatch'^[0-9a-f]{64}\z'-or
       $provenance.installerPackageManifest.name-cne'installer-package.manifest.json'-or[long]$provenance.installerPackageManifest.length-ne[long](Get-Item $packageManifestPath -Force).Length-or$provenance.installerPackageManifest.sha256-cne$packageManifestHash-or-not(Test-CcodReleaseContractJsonInteger $provenance.installerPackageManifest.fileCount 0)-or[long]$provenance.installerPackageManifest.fileCount-ne@($package.files).Count-or$provenance.installerPackageManifest.payloadManifestSha256-cne$package.payloadManifest.sha256-or
       $provenance.activationBootstrap.name-cne'Activate-CcodRemoteFix.ps1'-or[long]$provenance.activationBootstrap.length-lt1-or$provenance.activationBootstrap.sha256-cnotmatch'^[0-9a-f]{64}\z'-or$provenance.buildInputs.innoTemplateSha256-cnotmatch'^[0-9a-f]{64}\z'-or$provenance.buildInputs.destinationInventorySha256-cne(Get-CcodReleaseContractHash $inventoryPath)-or$provenance.buildInputs.compilerSha256-cnotmatch'^[0-9a-f]{64}\z'-or[string]::IsNullOrWhiteSpace([string]$provenance.buildInputs.compilerFileVersion)-or
       $provenance.peContract.fileVersion-cne"$Version.0"-or$provenance.peContract.packageManifestFirst-cne$packageManifestHash.Substring(0,32)-or$provenance.peContract.packageManifestLast-cne$packageManifestHash.Substring(32,32)-or$provenance.peContract.bootstrapFirst-cne$provenance.activationBootstrap.sha256.Substring(0,32)-or$provenance.peContract.bootstrapLast-cne$provenance.activationBootstrap.sha256.Substring(32,32)-or$provenance.peContract.companyName-cne$Manifest.gitCommit-or$provenance.peContract.legalCopyright-cne$provenance.installerPackage.sha256){Throw-CcodReleaseContractError $ErrorId 'Setup provenance values do not bind package manifest, inventory, PE, and common identity.' $provenancePath}
    $setupModule=Join-Path (Split-Path $PSScriptRoot -Parent) 'build\SetupArtifact.psm1'
    $setupLease = Open-CcodTrustedImportLease -Path $setupModule -ErrorId $ErrorId
    try {
        $setupModule = Assert-CcodReleaseContractPlainPath -Path $setupModule -Directory $false -ErrorId $ErrorId
        $setupLease.Revalidate()
        Import-Module $setupModule -Force -ErrorAction Stop
        $setupLease.Revalidate()
    } finally { $setupLease.Dispose() }
    try{$setup=Test-CcodSetupArtifact -SetupPath (Join-Path $Directory $names[5]) -ExpectedVersion $Version -ExpectedGitCommit $Manifest.gitCommit -ExpectedPackageSha256 $provenance.installerPackage.sha256 -ExpectedPackageManifestSha256 $packageManifestHash -ExpectedActivationBootstrapSha256 $provenance.activationBootstrap.sha256}catch{Throw-CcodReleaseContractError $ErrorId 'Setup PE does not bind its nested provenance.' $names[5]}
    return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=[string]$Manifest.gitCommit;BuildTimestampUtc=[string]$Manifest.buildTimestampUtc;InstallerSha256=[string]$map[$names[5]];InstallerName=$names[5];PackageManifestSha256=$packageManifestHash;SetupProvenanceName=$names[7];SetupPayloadInputName=$names[8];SetupInventoryInputName=$names[9]}
}

function Test-CcodReleaseAssetManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$ExpectedVersion)
    $errorId='CCOD_RELEASE_MANIFEST_INVALID';$directory=Assert-CcodReleaseContractPlainPath -Path $AssetDirectory -Directory $true -ErrorId $errorId;$manifestFile=Assert-CcodReleaseContractPlainPath -Path $ManifestPath -Directory $false -ErrorId $errorId;$json=Read-CcodReleaseContractJson -Path $manifestFile -ErrorId $errorId;$manifest=$json.Value
    if((Test-CcodReleaseContractJsonInteger $manifest.schemaVersion 2)-and[long]$manifest.schemaVersion-eq2){return Test-CcodReleasePortableManifestDeep -Manifest $manifest -ManifestRaw $json.Raw -ManifestPath $manifestFile -Directory $directory -Version $ExpectedVersion -ErrorId $errorId}
    if((Test-CcodReleaseContractJsonInteger $manifest.schemaVersion 1)-and[long]$manifest.schemaVersion-eq1){return Test-CcodReleaseSetupManifestDeep -Manifest $manifest -ManifestPath $manifestFile -Directory $directory -Version $ExpectedVersion -ErrorId $errorId}
    Throw-CcodReleaseContractError $errorId 'Release manifest schema is unsupported.' $manifestFile
}

function Assert-CcodReleaseContractMetadata {
    param($Value,[string]$Version,[string]$GitCommit,[string]$Timestamp,[string]$ErrorId,$Target,[switch]$TimestampOptional)
    if ($null -eq $Value -or $Value -isnot [pscustomobject] -or
        $null -eq $Value.PSObject.Properties['version'] -or $Value.version -isnot [string] -or $Value.version -cne $Version -or
        $null -eq $Value.PSObject.Properties['gitCommit'] -or $Value.gitCommit -isnot [string] -or $Value.gitCommit -cne $GitCommit) {
        Throw-CcodReleaseContractError $ErrorId 'Release metadata does not bind the common version and commit.' $Target
    }
    if (-not $TimestampOptional) {
        if ($null -eq $Value.PSObject.Properties['buildTimestampUtc'] -or -not (Test-CcodReleaseContractCanonicalUtc $Value.buildTimestampUtc) -or $Value.buildTimestampUtc -cne $Timestamp) {
            Throw-CcodReleaseContractError $ErrorId 'Release metadata does not bind the common canonical timestamp.' $Target
        }
    }
}

function Get-CcodReleaseContractManifestMap {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)]$Target
    )
    $assets = @($Manifest.assets)
    if ($assets.Count -ne $ExpectedNames.Count) { Throw-CcodReleaseContractError $ErrorId 'Release manifest asset count is not exact.' $Target }
    $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    for ($index=0; $index -lt $assets.Count; $index++) {
        $record = $assets[$index]
        if ($null -eq $record -or $record -isnot [pscustomobject] -or
            (@($record.PSObject.Properties.Name) -join ',') -cne 'name,sha256' -or
            $record.name -isnot [string] -or $record.name -cne $ExpectedNames[$index] -or
            $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            $map.ContainsKey([string]$record.name)) {
            Throw-CcodReleaseContractError $ErrorId 'Release manifest asset records are malformed, duplicated, or out of order.' $Target
        }
        $map.Add([string]$record.name,[string]$record.sha256)
    }
    return $map
}

function Test-CcodExactReleaseAssetSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$Version
    )
    $errorId = 'CCOD_RELEASE_ASSET_SET_INVALID'
    $authority=Open-CcodExactReleaseAssetAuthority -AssetDirectory $AssetDirectory -Version $Version -ErrorId $errorId
    try {
    $directory = Assert-CcodReleaseContractPlainPath -Path $AssetDirectory -Directory $true -ErrorId $errorId
    $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    try { $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
    catch { Throw-CcodReleaseContractError $errorId 'Release asset directory cannot be enumerated exactly.' $directory }
    if ($children.Count -ne $expected.Count) { Throw-CcodReleaseContractError $errorId 'Release asset directory does not contain exactly eleven entries.' $directory }
    $byName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($child in $children) {
        if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $byName.ContainsKey($child.Name)) {
            Throw-CcodReleaseContractError $errorId 'Release assets must be distinct regular non-reparse files.' $child.FullName
        }
        $byName.Add($child.Name,$child)
    }
    foreach ($name in $expected) {
        if (-not $byName.ContainsKey($name) -or [string]$byName[$name].Name -cne $name) {
            Throw-CcodReleaseContractError $errorId 'Release asset names differ by spelling, case, or membership.' $name
        }
        [void](Assert-CcodReleaseContractPlainPath -Path ([string]$byName[$name].FullName) -Directory $false -ErrorId $errorId)
    }

    $portablePath = Join-Path $directory $expected[4]
    $setupPath = Join-Path $directory $expected[10]
    try {
        $portableDeep = Test-CcodReleaseAssetManifest -ManifestPath $portablePath -AssetDirectory $directory -ExpectedVersion $Version
        $setupDeep = Test-CcodReleaseAssetManifest -ManifestPath $setupPath -AssetDirectory $directory -ExpectedVersion $Version
        if($portableDeep.GitCommit-cne$setupDeep.GitCommit-or$portableDeep.BuildTimestampUtc-cne$setupDeep.BuildTimestampUtc){throw 'distribution provenance mismatch'}
    } catch { Throw-CcodReleaseContractError $errorId 'Release distributions do not satisfy the shared deep asset contract.' $directory }
    $portableJson = Read-CcodReleaseContractJson -Path $portablePath -ErrorId $errorId
    $setupJson = Read-CcodReleaseContractJson -Path $setupPath -ErrorId $errorId
    $portable = $portableJson.Value; $setup = $setupJson.Value
    if ((@($portable.PSObject.Properties.Name) -join ',') -cne 'schemaVersion,product,version,gitCommit,buildTimestampUtc,distribution,assets' -or
        -not (Test-CcodReleaseContractJsonInteger $portable.schemaVersion 2) -or [long]$portable.schemaVersion -ne 2 -or $portable.product -isnot [string] -or $portable.product -cne 'CodexRemote-fix' -or
        $portable.version -isnot [string] -or $portable.version -cne $Version -or $portable.gitCommit -isnot [string] -or $portable.gitCommit -cnotmatch '^[0-9a-f]{40}\z' -or
        -not (Test-CcodReleaseContractCanonicalUtc $portable.buildTimestampUtc) -or $portable.distribution -cne 'portable-zip') {
        Throw-CcodReleaseContractError $errorId 'Portable release manifest metadata is not exact.' $portablePath
    }
    if ((@($setup.PSObject.Properties.Name) -join ',') -cne 'schemaVersion,product,version,gitCommit,buildTimestampUtc,assets' -or
        -not (Test-CcodReleaseContractJsonInteger $setup.schemaVersion 1) -or [long]$setup.schemaVersion -ne 1 -or $setup.product -isnot [string] -or $setup.product -cne 'CodexRemote-fix' -or
        $setup.version -isnot [string] -or $setup.version -cne $Version -or $setup.gitCommit -isnot [string] -or $setup.gitCommit -cne $portable.gitCommit -or
        -not (Test-CcodReleaseContractCanonicalUtc $setup.buildTimestampUtc) -or $setup.buildTimestampUtc -cne $portable.buildTimestampUtc) {
        Throw-CcodReleaseContractError $errorId 'Setup release manifest metadata is not exact or does not share provenance.' $setupPath
    }
    $portableNames = @($expected[0],$expected[1],$expected[2],$expected[3],'CodexRemote-fix.exe','CodexRemote-fix.exe.config')
    $setupNames = @($expected[5],$expected[6],$expected[2],$expected[7],$expected[8],$expected[9])
    $portableMap = Get-CcodReleaseContractManifestMap -Manifest $portable -ExpectedNames $portableNames -ErrorId $errorId -Target $portablePath
    $setupMap = Get-CcodReleaseContractManifestMap -Manifest $setup -ExpectedNames $setupNames -ErrorId $errorId -Target $setupPath
    foreach ($name in @($portableNames | Where-Object { $_ -in $expected })) {
        if ((Get-CcodReleaseContractHash (Join-Path $directory $name)) -cne $portableMap[$name]) { Throw-CcodReleaseContractError $errorId 'Portable manifest hash differs from the public asset bytes.' $name }
    }
    foreach ($name in $setupNames) {
        if ((Get-CcodReleaseContractHash (Join-Path $directory $name)) -cne $setupMap[$name]) { Throw-CcodReleaseContractError $errorId 'Setup manifest hash differs from the public asset bytes.' $name }
    }
    if ($portableMap[$expected[2]] -cne $setupMap[$expected[2]]) { Throw-CcodReleaseContractError $errorId 'Portable and Setup manifests do not share one TrayHost provenance identity.' $expected[2] }
    foreach ($pair in @(@($expected[0],$expected[1]),@($expected[5],$expected[6]))) {
        $checksumText = [IO.File]::ReadAllText((Join-Path $directory $pair[1]),[Text.UTF8Encoding]::new($false,$true)).TrimEnd("`r","`n")
        $assetHash = Get-CcodReleaseContractHash (Join-Path $directory $pair[0])
        if ($checksumText -cne ("$assetHash *$($pair[0])")) { Throw-CcodReleaseContractError $errorId 'Release checksum is not exact.' $pair[1] }
    }
    $tray = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[2]) -ErrorId $errorId).Value
    $portablePayload = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[3]) -ErrorId $errorId).Value
    $setupProvenance = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[7]) -ErrorId $errorId).Value
    $setupPayload = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[8]) -ErrorId $errorId).Value
    Assert-CcodReleaseContractMetadata $tray $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[2]
    Assert-CcodReleaseContractMetadata $portablePayload $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[3]
    Assert-CcodReleaseContractMetadata $setupProvenance $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[7]
    Assert-CcodReleaseContractMetadata $setupPayload $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[8] -TimestampOptional

    $records = [Collections.Generic.List[object]]::new()
    foreach ($name in $expected) { $records.Add([pscustomobject][ordered]@{name=$name;sha256=Get-CcodReleaseContractHash (Join-Path $directory $name)}) }
    Assert-CcodExactReleaseAssetAuthorityCurrent $authority $errorId|Out-Null
    return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=[string]$portable.gitCommit;BuildTimestampUtc=[string]$portable.buildTimestampUtc;Assets=@($records)}
    } finally { Close-CcodExactReleaseAssetAuthority $authority }
}

function Get-CcodReleasePromotionReceiptNames {
    param([string]$Version)
    @("CodexRemote-fix-$Version-setup.internet-download.defender.json","CodexRemote-fix-$Version-windows-x64.internet-download.defender.json")
}

function Test-CcodReleasePromotionReceipt {
    param($Receipt,[string]$Raw,[string]$Path,[string]$AssetType,[string]$Version,[string]$GitCommit,[string[]]$AssetNames,[datetime]$NowUtc = [datetime]::UtcNow)
    $errorId = 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
    if ((@($Receipt.PSObject.Properties.Name) -join ',') -cne ($script:CcodReleaseReceiptFields -join ',')) { Throw-CcodReleaseContractError $errorId 'Defender receipt fields or order are not exact.' $Path }
    foreach ($field in $script:CcodReleaseReceiptFields) {
        if ([regex]::Matches($Raw,'"'+[regex]::Escape($field)+'"\s*:').Count -ne 1) { Throw-CcodReleaseContractError $errorId 'Defender receipt contains a missing or duplicate field.' $Path }
    }
    $setup = $AssetType -ceq 'Setup'
    $expectedAsset = if ($setup) { $AssetNames[5] } else { $AssetNames[0] }
    $expectedChecksum = if ($setup) { $AssetNames[6] } else { $AssetNames[1] }
    $expectedManifest = if ($setup) { $AssetNames[10] } else { $AssetNames[4] }
    if (-not (Test-CcodReleaseContractJsonInteger $Receipt.schemaVersion 2) -or [long]$Receipt.schemaVersion -ne 2 -or
        $Receipt.assetType -isnot [string] -or $Receipt.assetType -cne $AssetType -or
        $Receipt.assetName -isnot [string] -or $Receipt.assetName -cne $expectedAsset -or
        $Receipt.assetSha256 -isnot [string] -or $Receipt.assetSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
        $Receipt.checksumName -isnot [string] -or $Receipt.checksumName -cne $expectedChecksum -or
        $Receipt.checksumSha256 -isnot [string] -or $Receipt.checksumSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
        $Receipt.manifestName -isnot [string] -or $Receipt.manifestName -cne $expectedManifest -or
        $Receipt.manifestSha256 -isnot [string] -or $Receipt.manifestSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
        $Receipt.version -isnot [string] -or $Receipt.version -cne $Version -or
        $Receipt.gitCommit -isnot [string] -or $Receipt.gitCommit -cne $GitCommit -or
        $Receipt.origin -isnot [string] -or $Receipt.origin -cne 'InternetDownload' -or
        $null -ne $Receipt.workflowArtifactIdentity -or -not (Test-CcodReleaseContractJsonInteger $Receipt.zoneId 3) -or [long]$Receipt.zoneId -ne 3 -or
        $Receipt.defenderServiceEnabled -isnot [bool] -or -not $Receipt.defenderServiceEnabled -or
        $Receipt.antivirusEnabled -isnot [bool] -or -not $Receipt.antivirusEnabled -or
        $Receipt.realTimeProtectionEnabled -isnot [bool] -or -not $Receipt.realTimeProtectionEnabled -or
        $Receipt.defenderPlatformVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.defenderPlatformVersion) -or $Receipt.defenderPlatformVersion.Length -gt 128 -or
        $Receipt.defenderEngineVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.defenderEngineVersion) -or $Receipt.defenderEngineVersion.Length -gt 128 -or
        $Receipt.signatureVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.signatureVersion) -or $Receipt.signatureVersion.Length -gt 128 -or
        -not (Test-CcodReleaseContractCanonicalUtc $Receipt.signatureUpdatedAtUtc) -or
        -not (Test-CcodReleaseContractCanonicalUtc $Receipt.scanStartedAtUtc) -or
        -not (Test-CcodReleaseContractCanonicalUtc $Receipt.scanCompletedAtUtc) -or
        -not (Test-CcodReleaseContractJsonInteger $Receipt.detectionCount 0) -or [long]$Receipt.detectionCount -ne 0 -or
        $Receipt.outcome -isnot [string] -or $Receipt.outcome -cne 'Completed' -or $null -ne $Receipt.errorCode) {
        Throw-CcodReleaseContractError $errorId 'Defender receipt does not bind a completed official download scan.' $Path
    }
    $signature = [datetime]::ParseExact($Receipt.signatureUpdatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $started = [datetime]::ParseExact($Receipt.scanStartedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $completed = [datetime]::ParseExact($Receipt.scanCompletedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if ($NowUtc.Kind -ne [DateTimeKind]::Utc -or $NowUtc -eq [datetime]::MinValue -or $NowUtc -eq [datetime]::MaxValue -or
        $started -gt $NowUtc.AddMinutes(5) -or $completed -gt $NowUtc.AddMinutes(5) -or
        $signature -lt $started.AddHours(-72) -or $signature -gt $started.AddMinutes(5) -or $completed -lt $started -or $completed -gt $started.AddHours(2)) {
        Throw-CcodReleaseContractError $errorId 'Defender receipt timestamps are stale, future-dated, reversed, or too long.' $Path
    }
    return $Receipt
}

function Test-CcodReleasePromotionEvidenceCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$Version,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}\z')][string]$ExpectedGitCommit,
        [scriptblock]$BeforeReturn,
        [hashtable]$HeldFileHashes
    )
    $errorId = 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
    $nowUtc = [datetime]::UtcNow
    $assetAuthority=$null;$evidenceAuthority=$null;$receiptAuthorities=[Collections.Generic.List[object]]::new();$heldFileDirectories=[Collections.Generic.List[object]]::new();$heldFileAuthorities=[Collections.Generic.List[object]]::new()
    try {
    $assetAuthority=Open-CcodExactReleaseAssetAuthority -AssetDirectory $AssetDirectory -Version $Version -ErrorId $errorId
    $directory = Assert-CcodReleaseContractPlainPath -Path $EvidenceDirectory -Directory $true -ErrorId $errorId
    try { $assetContract = Test-CcodExactReleaseAssetSet -AssetDirectory $AssetDirectory -Version $Version }
    catch { Throw-CcodReleaseContractError $errorId 'Promotion assets do not satisfy the exact eleven-file authority.' $AssetDirectory }
    if ($assetContract.GitCommit -cne $ExpectedGitCommit) { Throw-CcodReleaseContractError $errorId 'Promotion assets do not bind the expected commit.' $AssetDirectory }
    for($assetIndex=0;$assetIndex-lt11;$assetIndex++){if($assetAuthority.Files[$assetIndex].Sha256-cne$assetContract.Assets[$assetIndex].sha256){Throw-CcodReleaseContractError $errorId 'Pinned promotion asset differs from its validated contract.' $assetAuthority.Files[$assetIndex].Path}}
    $names = @(Get-CcodReleasePromotionReceiptNames -Version $Version)
    $evidenceAuthority=Open-CcodReleaseDirectoryAuthority -Path $directory -ErrorId $errorId;$expectedReceiptNames=[string[]]@($names);[Array]::Sort($expectedReceiptNames,[StringComparer]::Ordinal)
    if($evidenceAuthority.Children.Count-ne2-or($evidenceAuthority.Children-join"`0")-cne($expectedReceiptNames-join"`0")){Throw-CcodReleaseContractError $errorId 'Promotion requires exactly two named receipt leaves.' $directory}
    $assets = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    $receipts = [Collections.Generic.List[object]]::new()
    for ($index=0; $index -lt 2; $index++) {
        $receiptAuthority=Open-CcodReleaseFileAuthority -Directory $evidenceAuthority -Leaf $names[$index] -ErrorId $errorId -MaximumBytes 65536;$receiptAuthorities.Add($receiptAuthority);$path=$receiptAuthority.Path
        $json = Read-CcodReleaseContractPinnedJson -Authority $receiptAuthority -ErrorId $errorId -MaximumBytes 65536
        $type = if ($index -eq 0) { 'Setup' } else { 'PortableZip' }
        $receipts.Add((Test-CcodReleasePromotionReceipt -Receipt $json.Value -Raw $json.Raw -Path $path -AssetType $type -Version $Version -GitCommit $ExpectedGitCommit -AssetNames $assets -NowUtc $nowUtc))
    }
    foreach ($binding in @(
        [pscustomobject]@{Receipt=0;Asset=5;Checksum=6;Manifest=10},
        [pscustomobject]@{Receipt=1;Asset=0;Checksum=1;Manifest=4}
    )) {
        $receipt = $receipts[$binding.Receipt]
        if ($receipt.assetSha256 -cne $assetContract.Assets[$binding.Asset].sha256 -or
            $receipt.checksumSha256 -cne $assetContract.Assets[$binding.Checksum].sha256 -or
            $receipt.manifestSha256 -cne $assetContract.Assets[$binding.Manifest].sha256) {
            Throw-CcodReleaseContractError $errorId 'Promotion receipt hashes do not match the authoritative public asset bytes.' $directory
        }
    }
    if ($receipts[0].assetSha256 -ceq $receipts[1].assetSha256 -or
        $receipts[0].checksumSha256 -ceq $receipts[1].checksumSha256 -or
        $receipts[0].manifestSha256 -ceq $receipts[1].manifestSha256) {
        Throw-CcodReleaseContractError $errorId 'Setup and portable receipts reuse an evidence identity.' $directory
    }
    Assert-CcodExactReleaseAssetAuthorityCurrent $assetAuthority $errorId|Out-Null;Assert-CcodReleaseAuthorityCurrent $evidenceAuthority $errorId|Out-Null;foreach($authority in @($receiptAuthorities)){Assert-CcodReleaseAuthorityCurrent $authority $errorId -CheckBytes|Out-Null}
    if($null -ne $HeldFileHashes){foreach($entry in @($HeldFileHashes.GetEnumerator())){
        if($entry.Key-isnot[string]-or$entry.Value-isnot[string]-or$entry.Value-cnotmatch'^[0-9a-f]{64}\z'){throw 'held evidence hash'}
        $heldPath=Assert-CcodReleaseContractPlainPath -Path ([string]$entry.Key) -Directory $false -ErrorId $errorId
        $heldDirectory=Open-CcodReleaseDirectoryAuthority -Path ([IO.Path]::GetDirectoryName($heldPath)) -ErrorId $errorId
        $heldFileDirectories.Add($heldDirectory)
        $heldFile=Open-CcodReleaseFileAuthority -Directory $heldDirectory -Leaf ([IO.Path]::GetFileName($heldPath)) -ErrorId $errorId -MaximumBytes 4194304
        $heldFileAuthorities.Add($heldFile)
        if($heldFile.Sha256-cne[string]$entry.Value){throw 'held evidence bytes'}
    }}
    foreach($directoryAuthority in @($heldFileDirectories)){Assert-CcodReleaseAuthorityCurrent $directoryAuthority $errorId|Out-Null}
    foreach($authority in @($heldFileAuthorities)){Assert-CcodReleaseAuthorityCurrent $authority $errorId -CheckBytes|Out-Null}
    if($null-ne$BeforeReturn){
        &$BeforeReturn $assetAuthority $evidenceAuthority @($receiptAuthorities)
        Assert-CcodExactReleaseAssetAuthorityCurrent $assetAuthority $errorId|Out-Null
        Assert-CcodReleaseAuthorityCurrent $evidenceAuthority $errorId|Out-Null
        foreach($authority in @($receiptAuthorities)){Assert-CcodReleaseAuthorityCurrent $authority $errorId -CheckBytes|Out-Null}
        foreach($directoryAuthority in @($heldFileDirectories)){Assert-CcodReleaseAuthorityCurrent $directoryAuthority $errorId|Out-Null}
    foreach($authority in @($heldFileAuthorities)){Assert-CcodReleaseAuthorityCurrent $authority $errorId -CheckBytes|Out-Null}
    }
    return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=$ExpectedGitCommit;Receipts=@($receipts)}
    } finally {for($index=$heldFileAuthorities.Count-1;$index-ge0;$index--){Close-CcodReleaseAuthority $heldFileAuthorities[$index]};for($index=$heldFileDirectories.Count-1;$index-ge0;$index--){Close-CcodReleaseAuthority $heldFileDirectories[$index]};for($index=$receiptAuthorities.Count-1;$index-ge0;$index--){Close-CcodReleaseAuthority $receiptAuthorities[$index]};Close-CcodReleaseAuthority $evidenceAuthority;Close-CcodExactReleaseAssetAuthority $assetAuthority}
}

function Test-CcodReleasePromotionEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$Version,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}\z')][string]$ExpectedGitCommit)
    Test-CcodReleasePromotionEvidenceCore -EvidenceDirectory $EvidenceDirectory -AssetDirectory $AssetDirectory -Version $Version -ExpectedGitCommit $ExpectedGitCommit
}

Export-ModuleMember -Function Get-CcodExpectedReleaseAssetNames,Test-CcodExactReleaseAssetSet,Test-CcodReleaseAssetManifest,Test-CcodReleasePromotionEvidence
