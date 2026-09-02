Set-StrictMode -Version Latest

$script:CcodGenerationReclamationBeforeArmForTest = $null
$script:CcodGenerationReclamationFailFileArmAtForTest = -1
$script:CcodGenerationReclamationFailCommitAtForTest = -1

function Throw-CcodGenerationReclamationError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Initialize-CcodGenerationReclamationRuntime {
    $marker = 'CcodGenerationReclamationMarkerV1' -as [type]
    if ($null -eq $marker) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CcodGenerationReclamationMarkerV1
{
    private CcodGenerationReclamationMarkerV1() { }
    public static int CapabilityAbi { get { return 1; } }
}

internal sealed class CcodGenerationReclamationRollbackException : Exception
{
    internal CcodGenerationReclamationRollbackException(string message,Exception inner) : base(message,inner) { }
}

internal sealed class CcodGenerationReclamationCommitException : Exception
{
    internal CcodGenerationReclamationCommitException(string message,Exception inner) : base(message,inner) { }
}

internal sealed class CcodGenerationReclamationSnapshotV1
{
    internal sealed class FileRecord
    {
        public readonly string Path;
        public readonly long Length;
        public readonly string Sha256;
        internal FileRecord(string path,long length,string sha256) { Path=path;Length=length;Sha256=sha256; }
    }

    public readonly string ManifestText;
    public readonly FileRecord[] Files;
    public readonly string[] Directories;
    internal CcodGenerationReclamationSnapshotV1(string manifestText,FileRecord[] files,string[] directories)
    { ManifestText=manifestText;Files=files;Directories=directories; }
}

internal sealed class CcodGenerationReclamationRuntimeV1 : IDisposable
{
    private const uint READ_DATA=0x00000001, LIST_DIRECTORY=0x00000001, READ_ATTRIBUTES=0x00000080;
    private const uint DELETE=0x00010000, SYNCHRONIZE=0x00100000;
    private const uint SHARE_READ=0x00000001, SHARE_WRITE=0x00000002;
    private const uint OPEN=1, OPEN_EXISTING=3, OBJ_CASE_INSENSITIVE=0x40;
    private const uint DIRECTORY=0x00000001, SYNC_IO=0x00000020, BACKUP_INTENT=0x00004000, OPEN_REPARSE=0x00200000;
    private const uint FLAG_BACKUP=0x02000000, FLAG_REPARSE=0x00200000;
    private const uint ATTR_DIRECTORY=0x00000010, ATTR_REPARSE=0x00000400;
    private const uint DISPOSITION_DELETE=0x00000001, DISPOSITION_IGNORE_READONLY=0x00000010;
    private const int FileStreamInfo=7, FileDirectoryInformation=1, FileDispositionInfoEx=21;
    private const int STATUS_NO_MORE_FILES=unchecked((int)0x80000006);

    [StructLayout(LayoutKind.Sequential)] private struct UNICODE_STRING { public ushort Length,MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory,ObjectName; public uint Attributes; public IntPtr SecurityDescriptor,SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] private struct IO_STATUS_BLOCK { public IntPtr Status; public UIntPtr Information; }
    [StructLayout(LayoutKind.Sequential)] private struct FILETIME_NATIVE { public uint Low,High; }
    [StructLayout(LayoutKind.Sequential)] private struct FILE_INFO
    {
        public uint FileAttributes; public FILETIME_NATIVE CreationTime,LastAccessTime,LastWriteTime;
        public uint VolumeSerialNumber,FileSizeHigh,FileSizeLow,NumberOfLinks,FileIndexHigh,FileIndexLow;
    }

    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FILE_INFO information);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder buffer,uint length,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int informationClass,IntPtr information,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool SetFileInformationByHandle(SafeFileHandle handle,int informationClass,IntPtr information,uint size);
    [DllImport("ntdll.dll")] private static extern int NtCreateFile(out IntPtr handle,uint access,ref OBJECT_ATTRIBUTES attributes,out IO_STATUS_BLOCK io,IntPtr allocationSize,uint fileAttributes,uint share,uint disposition,uint options,IntPtr ea,uint eaLength);
    [DllImport("ntdll.dll")] private static extern int NtQueryDirectoryFile(SafeFileHandle handle,IntPtr evt,IntPtr apc,IntPtr context,out IO_STATUS_BLOCK io,IntPtr information,uint length,int informationClass,bool single,IntPtr name,bool restart);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);

    private sealed class Pin : IDisposable
    {
        internal readonly Pin Parent;
        internal readonly string Leaf,Path,RelativePath;
        internal readonly bool Directory;
        internal SafeFileHandle Handle;
        internal FileStream Stream;
        internal readonly uint Volume;
        internal readonly ulong FileId;
        internal readonly long Length;
        internal readonly string Sha256;
        internal readonly string[] Children;
        internal bool Armed,Closed;

        internal Pin(Pin parent,string leaf,string path,string relativePath,SafeFileHandle handle,FILE_INFO information,string[] children)
        {
            Parent=parent;Leaf=leaf;Path=path;RelativePath=relativePath;Directory=true;Handle=handle;
            Volume=information.VolumeSerialNumber;FileId=((ulong)information.FileIndexHigh<<32)|information.FileIndexLow;
            Length=-1;Sha256=null;Children=children;
        }

        internal Pin(Pin parent,string leaf,string path,string relativePath,FileStream stream,FILE_INFO information,long length,string sha256)
        {
            Parent=parent;Leaf=leaf;Path=path;RelativePath=relativePath;Directory=false;Stream=stream;
            Volume=information.VolumeSerialNumber;FileId=((ulong)information.FileIndexHigh<<32)|information.FileIndexLow;
            Length=length;Sha256=sha256;Children=null;
        }

        internal SafeFileHandle Native { get { return Directory?Handle:Stream.SafeFileHandle; } }
        public void Dispose()
        {
            if(Closed)return;
            if(Stream!=null)Stream.Dispose();else if(Handle!=null)Handle.Dispose();
            Closed=true;
        }
    }

    private readonly string installPath,runtimeParentPath,selectedPath;
    private Pin installRoot,runtimeParent,selectedRoot,manifest;
    private readonly List<Pin> files=new List<Pin>();
    private readonly List<Pin> directories=new List<Pin>();
    private bool disposed,completed;

    private CcodGenerationReclamationRuntimeV1(string installPath,string runtimeParentPath,string selectedPath)
    { this.installPath=installPath;this.runtimeParentPath=runtimeParentPath;this.selectedPath=selectedPath; }

    internal static CcodGenerationReclamationRuntimeV1 Open(string installPath,string selectedPath,string runtimeId)
    {
        CcodGenerationReclamationRuntimeV1 runtime=new CcodGenerationReclamationRuntimeV1(installPath,Path.Combine(installPath,"runtime"),selectedPath);
        try { runtime.OpenTree(runtimeId);return runtime; }
        catch { runtime.Dispose();throw; }
    }

    private void OpenTree(string runtimeId)
    {
        SafeFileHandle absolute=OpenAbsoluteDirectory(installPath);
        try { installRoot=CreateDirectoryPin(null,"",installPath,"",absolute,null);absolute=null; }
        finally { if(absolute!=null)absolute.Dispose(); }

        SafeFileHandle parentHandle=OpenRelative(installRoot.Native,"runtime",LIST_DIRECTORY|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ|SHARE_WRITE,DIRECTORY|BACKUP_INTENT);
        try { runtimeParent=CreateDirectoryPin(installRoot,"runtime",runtimeParentPath,"runtime",parentHandle,null);parentHandle=null; }
        finally { if(parentHandle!=null)parentHandle.Dispose(); }

        SafeFileHandle selectedHandle=OpenRelative(runtimeParent.Native,runtimeId,DELETE|LIST_DIRECTORY|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ,DIRECTORY|BACKUP_INTENT);
        try { selectedRoot=CreateDirectoryPin(runtimeParent,runtimeId,selectedPath,"",selectedHandle,null);selectedHandle=null;directories.Add(selectedRoot);OpenChildren(selectedRoot); }
        finally { if(selectedHandle!=null)selectedHandle.Dispose(); }

        if(installRoot.Volume!=runtimeParent.Volume||runtimeParent.Volume!=selectedRoot.Volume)throw new InvalidDataException("selected root volume ancestry changed");
        foreach(Pin file in files)if(String.Equals(file.RelativePath,"manifest.json",StringComparison.Ordinal)){if(manifest!=null)throw new InvalidDataException("duplicate manifest");manifest=file;}
        if(manifest==null)throw new InvalidDataException("manifest missing");
        Revalidate();
    }

    private void OpenChildren(Pin directory)
    {
        string[] leaves=Enumerate(directory.Native);
        for(int index=0;index<leaves.Length;index++)
        {
            string leaf=leaves[index];
            if(String.IsNullOrEmpty(leaf)||leaf=="."||leaf==".."||leaf.IndexOfAny(new[]{'\\','/',':'})>=0||leaf.EndsWith(".",StringComparison.Ordinal)||leaf.EndsWith(" ",StringComparison.Ordinal))throw new InvalidDataException("unsafe enumerated leaf");
            string path=Path.Combine(directory.Path,leaf),relative=String.IsNullOrEmpty(directory.RelativePath)?leaf:directory.RelativePath+"/"+leaf;
            SafeFileHandle handle=OpenRelative(directory.Native,leaf,DELETE|READ_DATA|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ,BACKUP_INTENT);
            try
            {
                FILE_INFO information=Info(handle);
                if((information.FileAttributes&ATTR_REPARSE)!=0)throw new InvalidDataException("reparse child");
                if(information.VolumeSerialNumber!=selectedRoot.Volume)throw new InvalidDataException("child volume changed");
                if(IsDirectory(information))
                {
                    Pin child=CreateDirectoryPin(directory,leaf,path,relative,handle,null);handle=null;directories.Add(child);OpenChildren(child);
                }
                else
                {
                    FileStream stream=null;
                    try
                    {
                        stream=new FileStream(handle,FileAccess.Read,65536,false);handle=null;
                        FILE_INFO current=Info(stream.SafeFileHandle);ValidateFileIdentity(current,stream.SafeFileHandle,path,selectedRoot.Volume);
                        long length=stream.Length;string sha=Sha(stream);Pin child=new Pin(directory,leaf,path,relative,stream,current,length,sha);stream=null;files.Add(child);
                    }
                    finally { if(stream!=null)stream.Dispose(); }
                }
            }
            finally { if(handle!=null)handle.Dispose(); }
        }
    }

    internal CcodGenerationReclamationSnapshotV1 Snapshot()
    {
        if(disposed)throw new ObjectDisposedException("generation reclamation");
        Revalidate();
        List<CcodGenerationReclamationSnapshotV1.FileRecord> fileRecords=new List<CcodGenerationReclamationSnapshotV1.FileRecord>();
        foreach(Pin file in files)fileRecords.Add(new CcodGenerationReclamationSnapshotV1.FileRecord(file.RelativePath,file.Length,file.Sha256));
        fileRecords.Sort(delegate(CcodGenerationReclamationSnapshotV1.FileRecord left,CcodGenerationReclamationSnapshotV1.FileRecord right){return StringComparer.Ordinal.Compare(left.Path,right.Path);});
        List<string> directoryPaths=new List<string>();foreach(Pin directory in directories)if(!Object.ReferenceEquals(directory,selectedRoot))directoryPaths.Add(directory.RelativePath);
        directoryPaths.Sort(StringComparer.Ordinal);
        return new CcodGenerationReclamationSnapshotV1(ReadText(manifest.Stream),fileRecords.ToArray(),directoryPaths.ToArray());
    }

    internal void Reclaim(int failFileArmAt,int failCommitAt)
    {
        if(disposed)throw new ObjectDisposedException("generation reclamation");
        if(completed)throw new InvalidOperationException("generation already reclaimed");
        Revalidate();
        List<Pin> armed=new List<Pin>();
        try
        {
            int armIndex=0;
            foreach(Pin file in files)
            {
                armIndex++;
                if(failFileArmAt>0&&armIndex==failFileArmAt)throw new IOException("injected file-arm failure");
                SetDisposition(file.Native,true);file.Armed=true;armed.Add(file);
            }
        }
        catch(Exception armFailure)
        {
            Exception rollbackFailure=null;
            for(int index=armed.Count-1;index>=0;index--)
            {
                Pin file=armed[index];
                try { SetDisposition(file.Native,false);file.Armed=false; }
                catch(Exception exception) { if(rollbackFailure==null)rollbackFailure=exception; }
            }
            try { Revalidate(); } catch(Exception exception) { if(rollbackFailure==null)rollbackFailure=exception; }
            if(rollbackFailure!=null)throw new CcodGenerationReclamationRollbackException("PinnedValidated rollback failed after FilesArmed rejection",rollbackFailure);
            throw new InvalidDataException("FilesArmed rejected and the complete tree was disarmed: "+armFailure.Message,armFailure);
        }

        Exception commitFailure=null;int commitIndex=0;
        foreach(Pin file in SortedFilesForCommit())
        {
            commitIndex++;
            try { if(failCommitAt>0&&commitIndex==failCommitAt)throw new IOException("injected CommitStarted file-close failure");file.Dispose(); }
            catch(Exception exception) { if(commitFailure==null)commitFailure=exception; }
        }
        foreach(Pin directory in SortedDirectoriesForCommit())
        {
            commitIndex++;
            try { if(failCommitAt>0&&commitIndex==failCommitAt)throw new IOException("injected CommitStarted directory-mark failure");SetDisposition(directory.Native,true);directory.Armed=true;directory.Dispose(); }
            catch(Exception exception) { if(commitFailure==null)commitFailure=exception; }
        }
        if(commitFailure==null&&(Directory.Exists(selectedPath)||File.Exists(selectedPath)))commitFailure=new IOException("selected root remains after handle commit");
        if(commitFailure!=null)throw new CcodGenerationReclamationCommitException("CommitStarted generation reclamation failed",commitFailure);
        completed=true;
    }

    private List<Pin> SortedFilesForCommit()
    {
        List<Pin> ordered=new List<Pin>(files);ordered.Sort(delegate(Pin left,Pin right){int depth=Depth(right.RelativePath).CompareTo(Depth(left.RelativePath));return depth!=0?depth:StringComparer.Ordinal.Compare(left.RelativePath,right.RelativePath);});return ordered;
    }

    private List<Pin> SortedDirectoriesForCommit()
    {
        List<Pin> ordered=new List<Pin>(directories);ordered.Sort(delegate(Pin left,Pin right){int depth=Depth(right.RelativePath).CompareTo(Depth(left.RelativePath));return depth!=0?depth:StringComparer.Ordinal.Compare(left.RelativePath,right.RelativePath);});return ordered;
    }

    private static int Depth(string relative){if(String.IsNullOrEmpty(relative))return 0;int depth=1;for(int index=0;index<relative.Length;index++)if(relative[index]=='/')depth++;return depth;}

    private void Revalidate()
    {
        ValidateDirectoryIdentity(installRoot,installPath);
        ValidateDirectoryIdentity(runtimeParent,runtimeParentPath);
        ValidateDirectoryIdentity(selectedRoot,selectedPath);
        if(installRoot.Volume!=runtimeParent.Volume||runtimeParent.Volume!=selectedRoot.Volume)throw new InvalidDataException("selected root volume ancestry changed");
        foreach(Pin directory in directories)
        {
            ValidateDirectoryIdentity(directory,directory.Path);
            string[] current=Enumerate(directory.Native),expected=directory.Children;
            if(current.Length!=expected.Length)throw new InvalidDataException("directory membership changed");
            for(int index=0;index<current.Length;index++)if(!String.Equals(current[index],expected[index],StringComparison.Ordinal))throw new InvalidDataException("directory membership changed");
        }
        foreach(Pin file in files)
        {
            FILE_INFO information=Info(file.Native);ValidateFileIdentity(information,file.Native,file.Path,selectedRoot.Volume);
            ulong id=((ulong)information.FileIndexHigh<<32)|information.FileIndexLow;
            if(information.VolumeSerialNumber!=file.Volume||id!=file.FileId||file.Stream.Length!=file.Length||!String.Equals(Sha(file.Stream),file.Sha256,StringComparison.Ordinal))throw new InvalidDataException("file identity or bytes changed");
        }
    }

    private static Pin CreateDirectoryPin(Pin parent,string leaf,string path,string relative,SafeFileHandle handle,string[] knownChildren)
    {
        FILE_INFO information=Info(handle);ValidateDirectoryIdentity(information,handle,path);
        string[] children=knownChildren??Enumerate(handle);
        return new Pin(parent,leaf,path,relative,handle,information,children);
    }

    private static void ValidateDirectoryIdentity(Pin pin,string path)
    {
        if(pin==null||pin.Closed)throw new InvalidDataException("directory pin closed");
        FILE_INFO information=Info(pin.Native);ValidateDirectoryIdentity(information,pin.Native,path);
        ulong id=((ulong)information.FileIndexHigh<<32)|information.FileIndexLow;
        if(information.VolumeSerialNumber!=pin.Volume||id!=pin.FileId)throw new InvalidDataException("directory identity changed");
    }

    private static void ValidateDirectoryIdentity(FILE_INFO information,SafeFileHandle handle,string path)
    {
        if(!IsDirectory(information)||(information.FileAttributes&ATTR_REPARSE)!=0||!OnlyDefaultStream(handle)||!SamePath(FinalPath(handle),path))throw new InvalidDataException("directory identity invalid");
    }

    private static void ValidateFileIdentity(FILE_INFO information,SafeFileHandle handle,string path,uint expectedVolume)
    {
        if(IsDirectory(information)||(information.FileAttributes&ATTR_REPARSE)!=0||information.NumberOfLinks!=1||information.VolumeSerialNumber!=expectedVolume||!OnlyDefaultStream(handle)||!SamePath(FinalPath(handle),path))throw new InvalidDataException("file identity invalid");
    }

    private static SafeFileHandle OpenAbsoluteDirectory(string path)
    {
        SafeFileHandle handle=CreateFileW(path,LIST_DIRECTORY|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ|SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,FLAG_BACKUP|FLAG_REPARSE,IntPtr.Zero);
        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}return handle;
    }

    private static SafeFileHandle OpenRelative(SafeFileHandle parent,string name,uint access,uint share,uint options)
    {
        IntPtr nameBuffer=IntPtr.Zero,unicodePointer=IntPtr.Zero;bool added=false;
        try
        {
            parent.DangerousAddRef(ref added);nameBuffer=Marshal.StringToHGlobalUni(name);
            UNICODE_STRING unicode=new UNICODE_STRING{Length=(ushort)(name.Length*2),MaximumLength=(ushort)((name.Length+1)*2),Buffer=nameBuffer};
            unicodePointer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));Marshal.StructureToPtr(unicode,unicodePointer,false);
            OBJECT_ATTRIBUTES attributes=new OBJECT_ATTRIBUTES{Length=Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)),RootDirectory=parent.DangerousGetHandle(),ObjectName=unicodePointer,Attributes=OBJ_CASE_INSENSITIVE};
            IO_STATUS_BLOCK io;IntPtr raw;int status=NtCreateFile(out raw,access,ref attributes,out io,IntPtr.Zero,0,share,OPEN,options|SYNC_IO|OPEN_REPARSE,IntPtr.Zero,0);
            if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));return new SafeFileHandle(raw,true);
        }
        finally { if(unicodePointer!=IntPtr.Zero)Marshal.FreeHGlobal(unicodePointer);if(nameBuffer!=IntPtr.Zero)Marshal.FreeHGlobal(nameBuffer);if(added)parent.DangerousRelease(); }
    }

    private static FILE_INFO Info(SafeFileHandle handle){FILE_INFO information;if(handle==null||handle.IsClosed||!GetFileInformationByHandle(handle,out information))throw new Win32Exception(Marshal.GetLastWin32Error());return information;}
    private static bool IsDirectory(FILE_INFO information){return(information.FileAttributes&ATTR_DIRECTORY)!=0;}

    private static string Sha(FileStream stream)
    {
        long position=stream.Position;try{stream.Position=0;using(SHA256 sha=SHA256.Create()){return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","").ToLowerInvariant();}}finally{stream.Position=position;}
    }

    private static string ReadText(FileStream stream)
    {
        if(stream.Length<1||stream.Length>4194304)throw new InvalidDataException("manifest size invalid");long position=stream.Position;
        try{stream.Position=0;byte[] bytes=new byte[(int)stream.Length];int offset=0;while(offset<bytes.Length){int read=stream.Read(bytes,offset,bytes.Length-offset);if(read==0)throw new EndOfStreamException();offset+=read;}return new UTF8Encoding(false,true).GetString(bytes);}
        finally{stream.Position=position;}
    }

    private static string FinalPath(SafeFileHandle handle)
    {
        StringBuilder buffer=new StringBuilder(512);uint length=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,0);
        if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());if(length>=buffer.Capacity){buffer.Capacity=(int)length+1;length=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,0);if(length==0||length>=buffer.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());}
        string path=buffer.ToString();if(path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return @"\\"+path.Substring(8);if(path.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return path.Substring(4);return path;
    }

    private static bool SamePath(string first,string second){return String.Equals(Path.GetFullPath(first).TrimEnd('\\'),Path.GetFullPath(second).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);}

    private static bool OnlyDefaultStream(SafeFileHandle handle)
    {
        IntPtr buffer=Marshal.AllocHGlobal(65536);
        try
        {
            if(!GetFileInformationByHandleEx(handle,FileStreamInfo,buffer,65536)){int error=Marshal.GetLastWin32Error();if(error==38)return true;throw new Win32Exception(error);}
            int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+4);string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+24),(int)nameLength/2);if(!String.Equals(name,"::$DATA",StringComparison.OrdinalIgnoreCase)&&!String.Equals(name,"::$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase))return false;if(next==0)break;offset+=(int)next;}return true;
        }
        finally{Marshal.FreeHGlobal(buffer);}
    }

    private static string[] Enumerate(SafeFileHandle handle)
    {
        List<string> result=new List<string>();HashSet<string> seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);IntPtr buffer=Marshal.AllocHGlobal(65536);bool restart=true;
        try
        {
            while(true)
            {
                IO_STATUS_BLOCK io;int status=NtQueryDirectoryFile(handle,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out io,buffer,65536,FileDirectoryInformation,false,IntPtr.Zero,restart);restart=false;
                if(status==STATUS_NO_MORE_FILES)break;if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));int offset=0;
                while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+60);string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+64),(int)nameLength/2);if(name!="."&&name!=".."){if(!seen.Add(name))throw new InvalidDataException("duplicate directory entry");result.Add(name);}if(next==0)break;offset+=(int)next;}
            }
            result.Sort(StringComparer.Ordinal);return result.ToArray();
        }
        finally{Marshal.FreeHGlobal(buffer);}
    }

    private static void SetDisposition(SafeFileHandle handle,bool delete)
    {
        IntPtr buffer=Marshal.AllocHGlobal(4);
        try{Marshal.WriteInt32(buffer,delete?unchecked((int)(DISPOSITION_DELETE|DISPOSITION_IGNORE_READONLY)):0);if(!SetFileInformationByHandle(handle,FileDispositionInfoEx,buffer,4))throw new Win32Exception(Marshal.GetLastWin32Error());}
        finally{Marshal.FreeHGlobal(buffer);}
    }

    public void Dispose()
    {
        if(disposed)return;disposed=true;
        for(int index=files.Count-1;index>=0;index--){try{files[index].Dispose();}catch{}}
        for(int index=directories.Count-1;index>=0;index--){try{directories[index].Dispose();}catch{}}
        try{if(runtimeParent!=null)runtimeParent.Dispose();}catch{}
        try{if(installRoot!=null)installRoot.Dispose();}catch{}
    }
}
'@
        $marker = 'CcodGenerationReclamationMarkerV1' -as [type]
    }
    if($null-eq$marker-or[int]$marker.GetProperty('CapabilityAbi').GetValue($null,$null)-ne1){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_ABI_INVALID' 'Generation reclamation native ABI is unavailable' $null}
    $script:CcodGenerationReclamationRuntimeType=$marker.Assembly.GetType('CcodGenerationReclamationRuntimeV1',$true)
}

function Invoke-CcodGenerationReclamationStatic {
    param([Parameter(Mandatory)][string]$Name,[object[]]$Arguments)
    $method=$script:CcodGenerationReclamationRuntimeType.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    try{return $method.Invoke($null,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}
}

function Invoke-CcodGenerationReclamationMethod {
    param([Parameter(Mandatory)]$Runtime,[Parameter(Mandatory)][string]$Name,[object[]]$Arguments)
    $method=$Runtime.GetType().GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Instance')
    try{return $method.Invoke($Runtime,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}
}

function Test-CcodGenerationReclamationJsonHasNoDuplicateProperties {
    param([AllowNull()][string]$Json)
    if($null-eq$Json){return $false};$objects=[Collections.Generic.Stack[object]]::new()
    for($index=0;$index-lt$Json.Length;$index++){
        $character=$Json[$index]
        if($character-eq'{'){$objects.Push([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal));continue}
        if($character-eq'}'){if($objects.Count-eq0){return $false};[void]$objects.Pop();continue}
        if($character-ne'"'){continue};$name=[Text.StringBuilder]::new();$index++
        while($index-lt$Json.Length){$character=$Json[$index];if($character-eq'"'){break};if($character-ne[char]92){[void]$name.Append($character);$index++;continue};$index++;if($index-ge$Json.Length){return $false};$escape=$Json[$index];if($escape-eq'u'){if($index+4-ge$Json.Length){return $false};try{[void]$name.Append([char][Convert]::ToInt32($Json.Substring($index+1,4),16))}catch{return $false};$index+=5;continue};switch([string]$escape){'"'{$decoded='"'}'\'{$decoded=[char]92}'/'{$decoded='/'}'b'{$decoded=[char]8}'f'{$decoded=[char]12}'n'{$decoded=[char]10}'r'{$decoded=[char]13}'t'{$decoded=[char]9}default{return $false}};[void]$name.Append($decoded);$index++}
        if($index-ge$Json.Length){return $false};$next=$index+1;while($next-lt$Json.Length-and[char]::IsWhiteSpace($Json[$next])){$next++};if($next-lt$Json.Length-and$Json[$next]-eq':'){if($objects.Count-eq0-or-not$objects.Peek().Add($name.ToString())){return $false}}
    }
    return $objects.Count-eq0
}

function Test-CcodGenerationReclamationExactProperties {
    param($Value,[string[]]$Expected)
    if($null-eq$Value-or$Value-isnot[pscustomobject]){return $false};$actual=@($Value.PSObject.Properties.Name);if($actual.Count-ne$Expected.Count){return $false};for($index=0;$index-lt$actual.Count;$index++){if($actual[$index]-cne$Expected[$index]){return $false}};return $true
}

function ConvertTo-CcodGenerationReclamationRecord {
    param([Parameter(Mandatory)]$Record)
    if(-not(Test-CcodGenerationReclamationExactProperties $Record @('path','length','sha256'))-or$Record.path-isnot[string]-or$Record.path-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$'-or$Record.path.Contains('//')-or$Record.path-match'(^|/)(?:\.|\.\.)(?:/|$)'-or$Record.path.Equals('manifest.json',[StringComparison]::OrdinalIgnoreCase)-or$Record.sha256-isnot[string]-or$Record.sha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'A pinned manifest record is invalid' $Record}
    $integerTypes=@([byte],[uint16],[uint32],[uint64],[int16],[int32],[int64]);$integer=$false;foreach($type in $integerTypes){if($Record.length-is$type){$integer=$true;break}};if(-not$integer){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'A pinned manifest length is not an integer' $Record};try{$length=[int64]$Record.length}catch{Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'A pinned manifest length is outside Int64' $Record};if($length-lt0){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'A pinned manifest length is negative' $Record}
    [pscustomobject][ordered]@{path=[string]$Record.path;length=$length;sha256=[string]$Record.sha256}
}

function Get-CcodGenerationReclamationRuntimeId {
    param([Parameter(Mandatory)][string]$ProjectVersion,[Parameter(Mandatory)][object[]]$Records,[Parameter(Mandatory)][string]$Nonce)
    if($ProjectVersion-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,45}$'-or$Nonce-cnotmatch'^[0-9a-f]{32}$'){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest identity components are invalid' $ProjectVersion};$lines=[Collections.Generic.List[string]]::new();foreach($record in $Records){$lines.Add(('{0}`t{1}`t{2}'-f$record.path,[int64]$record.length,$record.sha256))};$sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines-join"`n")))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};'{0}-{1}-{2}'-f$ProjectVersion,$digest.Substring(0,16),$Nonce
}

function Assert-CcodGenerationReclamationSnapshot {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)][string]$ExpectedManifestSha256)
    $files=@($Snapshot.Files);$manifestFile=@($files|Where-Object{$_.Path-ceq'manifest.json'});if($manifestFile.Count-ne1-or[string]$manifestFile[0].Sha256-cne$ExpectedManifestSha256){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest hash does not match the durable binding' $RuntimeId}
    try{$json=[string]$Snapshot.ManifestText;if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $json)){throw 'duplicate properties'};$manifest=$json|ConvertFrom-Json -ErrorAction Stop}catch{Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest JSON is malformed or ambiguous' $RuntimeId}
    if(-not(Test-CcodGenerationReclamationExactProperties $manifest @('schemaVersion','projectVersion','runtimeId','files'))-or$manifest.schemaVersion-isnot[int]-or$manifest.schemaVersion-ne1-or$manifest.projectVersion-isnot[string]-or$manifest.runtimeId-isnot[string]-or$manifest.runtimeId-cne$RuntimeId-or$null-eq$manifest.files){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest header is invalid' $RuntimeId}
    $records=[Collections.Generic.List[object]]::new();$previous=$null;foreach($record in @($manifest.files)){$validated=ConvertTo-CcodGenerationReclamationRecord $record;if($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,$validated.path)-ge0){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest records are not strictly ordered' $RuntimeId};$previous=$validated.path;$records.Add($validated)}
    $match=[regex]::Match($RuntimeId,'^(?<version>[A-Za-z0-9][A-Za-z0-9._-]{0,45})-(?<digest>[0-9a-f]{16})-(?<nonce>[0-9a-f]{32})$');if(-not$match.Success-or$match.Groups['version'].Value-cne$manifest.projectVersion-or(Get-CcodGenerationReclamationRuntimeId -ProjectVersion $manifest.projectVersion -Records $records.ToArray() -Nonce $match.Groups['nonce'].Value)-cne$RuntimeId){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest is not bound to the selected runtime ID' $RuntimeId}
    $expectedFiles=[Collections.Generic.List[object]]::new();foreach($record in $records){$expectedFiles.Add($record)};$expectedFiles.Add([pscustomobject]@{path='manifest.json';length=[int64]$manifestFile[0].Length;sha256=[string]$manifestFile[0].Sha256});$expectedFiles.Sort([Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)})
    if($files.Count-ne$expectedFiles.Count){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned tree contains an unexpected or missing file' $RuntimeId};for($index=0;$index-lt$files.Count;$index++){$actual=$files[$index];$expected=$expectedFiles[$index];if([string]$actual.Path-cne[string]$expected.path-or[int64]$actual.Length-ne[int64]$expected.length-or[string]$actual.Sha256-cne[string]$expected.sha256){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned tree differs from its sealed manifest' $actual.Path}}
    $expectedDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($record in $records){$segments=[string]$record.path-split'/';for($count=1;$count-lt$segments.Count;$count++){[void]$expectedDirectories.Add(($segments[0..($count-1)]-join'/'))}};$expectedDirectoryList=@($expectedDirectories);[Array]::Sort($expectedDirectoryList,[StringComparer]::Ordinal);$actualDirectories=@($Snapshot.Directories);if($actualDirectories.Count-ne$expectedDirectoryList.Count){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned tree contains an unexpected or missing directory' $RuntimeId};for($index=0;$index-lt$actualDirectories.Count;$index++){if([string]$actualDirectories[$index]-cne[string]$expectedDirectoryList[$index]){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned directory set differs from the sealed manifest' $actualDirectories[$index]}}
    [pscustomobject]@{FileCount=$files.Count;DirectoryCount=$actualDirectories.Count+1}
}

function Remove-CcodVerifiedGenerationTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][string]$ExpectedManifestSha256
    )
    try{$install=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\');$runtime=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')}catch{Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Generation reclamation paths are invalid' $RuntimeRoot}
    if(-not[IO.Path]::IsPathRooted($InstallRoot)-or-not[IO.Path]::IsPathRooted($RuntimeRoot)-or$RuntimeId-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'-or$RuntimeId-in@('.','..')-or$RuntimeId.EndsWith('.')-or$ExpectedManifestSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Generation reclamation inputs are invalid' $RuntimeRoot}
    $expected=[IO.Path]::GetFullPath((Join-Path (Join-Path $install 'runtime') $RuntimeId)).TrimEnd('\');if($runtime-cne$expected){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Runtime root is not the exact selected install generation leaf' $RuntimeRoot}
    Initialize-CcodGenerationReclamationRuntime;$native=$null
    try{
        $native=Invoke-CcodGenerationReclamationStatic -Name Open -Arguments @($install,$runtime,$RuntimeId);$snapshot=Invoke-CcodGenerationReclamationMethod -Runtime $native -Name Snapshot -Arguments @();$proof=Assert-CcodGenerationReclamationSnapshot -Snapshot $snapshot -RuntimeId $RuntimeId -ExpectedManifestSha256 $ExpectedManifestSha256
        if($script:CcodGenerationReclamationBeforeArmForTest-is[scriptblock]){&$script:CcodGenerationReclamationBeforeArmForTest}
        [void](Invoke-CcodGenerationReclamationMethod -Runtime $native -Name Reclaim -Arguments @([int]$script:CcodGenerationReclamationFailFileArmAtForTest,[int]$script:CcodGenerationReclamationFailCommitAtForTest))
        [pscustomobject][ordered]@{phase='Completed';result='Reclaimed';runtimeId=$RuntimeId;fileCount=[int]$proof.FileCount;directoryCount=[int]$proof.DirectoryCount}
    }catch{
        $exception=$_.Exception;while($null-ne$exception.InnerException-and$exception-is[Management.Automation.RuntimeException]){$exception=$exception.InnerException};$type=[string]$exception.GetType().Name
        if($type-ceq'CcodGenerationReclamationRollbackException'){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_ROLLBACK_FAILED' $exception.Message $RuntimeRoot}
        if($type-ceq'CcodGenerationReclamationCommitException'){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED' $exception.Message $RuntimeRoot}
        if(([string]$_.FullyQualifiedErrorId-split',')[0]-match'^CCOD_GENERATION_RECLAMATION_'){throw}
        Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' ('PinnedValidated generation reclamation rejected: '+$exception.Message) $RuntimeRoot
    }finally{if($null-ne$native){try{$native.Dispose()}catch{}}}
}

Export-ModuleMember -Function Remove-CcodVerifiedGenerationTree
