Set-StrictMode -Version Latest

$script:CcodGenerationReclamationBeforeArmForTest = $null
$script:CcodGenerationReclamationFailFileArmAtForTest = -1
$script:CcodGenerationReclamationFailCommitAtForTest = -1
$script:CcodProductResidueFailCommitAtForTest = -1

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
    private readonly List<Pin> residueAncestors=new List<Pin>();
    private bool disposed,completed;

    private CcodGenerationReclamationRuntimeV1(string installPath,string runtimeParentPath,string selectedPath)
    { this.installPath=installPath;this.runtimeParentPath=runtimeParentPath;this.selectedPath=selectedPath; }

    internal static CcodGenerationReclamationRuntimeV1 Open(string installPath,string selectedPath,string runtimeId)
    {
        CcodGenerationReclamationRuntimeV1 runtime=new CcodGenerationReclamationRuntimeV1(installPath,Path.Combine(installPath,"runtime"),selectedPath);
        try { runtime.OpenTree(runtimeId);return runtime; }
        catch { runtime.Dispose();throw; }
    }

    internal static CcodGenerationReclamationRuntimeV1 OpenResidue(string path)
    {
        string parentPath=Directory.GetParent(path).FullName;
        var runtime=new CcodGenerationReclamationRuntimeV1(parentPath,parentPath,path);
        try
        {
            var ancestors=new List<string>();
            for(DirectoryInfo cursor=new DirectoryInfo(parentPath);cursor!=null;cursor=cursor.Parent)ancestors.Add(cursor.FullName);
            ancestors.Reverse();Pin parent=null;
            foreach(string ancestor in ancestors)
            {
                SafeFileHandle handle=parent==null?OpenAbsoluteDirectory(ancestor):OpenRelative(parent.Native,Path.GetFileName(ancestor),LIST_DIRECTORY|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ|SHARE_WRITE,DIRECTORY|BACKUP_INTENT);
                try { parent=CreateDirectoryPin(parent,Path.GetFileName(ancestor),ancestor,"",handle,new string[0]);handle=null;runtime.residueAncestors.Add(parent); }
                finally { if(handle!=null)handle.Dispose(); }
            }
            runtime.installRoot=parent;
            SafeFileHandle selected=OpenRelative(parent.Native,Path.GetFileName(path),DELETE|LIST_DIRECTORY|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ,DIRECTORY|BACKUP_INTENT);
            try { runtime.selectedRoot=CreateDirectoryPin(parent,Path.GetFileName(path),path,"",selected,null);selected=null;runtime.directories.Add(runtime.selectedRoot);runtime.OpenChildren(runtime.selectedRoot); }
            finally { if(selected!=null)selected.Dispose(); }
            runtime.Revalidate();return runtime;
        }
        catch { runtime.Dispose();throw; }
    }

    internal string ReadFileText(string relative)
    {
        if(disposed)throw new ObjectDisposedException("product residue");
        foreach(Pin file in files)if(String.Equals(file.RelativePath,relative,StringComparison.Ordinal))return ReadText(file.Stream);
        throw new InvalidDataException("required product state is missing");
    }

    internal string RootIdentity()
    {
        Revalidate();return selectedRoot.Volume.ToString(System.Globalization.CultureInfo.InvariantCulture)+"-"+selectedRoot.FileId.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    internal sealed class Journal : IDisposable
    {
        private readonly List<SafeFileHandle> handles=new List<SafeFileHandle>();
        public FileStream Stream;
        public bool Created;
        internal Journal(string directory,string leaf)
        {
            try
            {
                var ancestors=new List<string>();
                for(DirectoryInfo cursor=new DirectoryInfo(directory);cursor!=null;cursor=cursor.Parent)ancestors.Add(cursor.FullName);
                ancestors.Reverse();SafeFileHandle parent=null;
                foreach(string path in ancestors)
                {
                    SafeFileHandle handle=parent==null?OpenAbsoluteDirectory(path):OpenRelative(parent,Path.GetFileName(path),LIST_DIRECTORY|READ_ATTRIBUTES|SYNCHRONIZE,SHARE_READ|SHARE_WRITE,DIRECTORY|BACKUP_INTENT);
                    handles.Add(handle);ValidateDirectoryIdentity(Info(handle),handle,path);parent=handle;
                }
                string target=Path.Combine(directory,leaf);
                try { Stream=new FileStream(target,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read,4096,FileOptions.WriteThrough);Created=true; }
                catch(IOException exception)
                {
                    int error=exception.HResult&65535;if(error!=80&&error!=183)throw;
                    Stream=new FileStream(target,FileMode.Open,FileAccess.Read,FileShare.Read);
                }
                ValidateFileIdentity(Info(Stream.SafeFileHandle),Stream.SafeFileHandle,target,Info(parent).VolumeSerialNumber);
            }
            catch { Dispose();throw; }
        }
        public void Dispose(){if(Stream!=null){Stream.Dispose();Stream=null;}for(int index=handles.Count-1;index>=0;index--)handles[index].Dispose();handles.Clear();}
    }

    internal static Journal OpenJournal(string directory){return new Journal(directory,"product-residue-plan.json");}

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
        if(Depth(directory.RelativePath)>32||directories.Count>4096||files.Count>16384)throw new InvalidDataException("bounded tree limit");
        string[] leaves=Enumerate(directory.Native);
        for(int index=0;index<leaves.Length;index++)
        {
            string leaf=leaves[index];
            if(String.IsNullOrEmpty(leaf)||leaf=="."||leaf==".."||leaf.IndexOfAny(new[]{'\\','/',':'})>=0||leaf.EndsWith(".",StringComparison.Ordinal)||leaf.EndsWith(" ",StringComparison.Ordinal))throw new InvalidDataException("unsafe enumerated leaf");
            if(runtimeParent==null&&(String.Equals(leaf,"device-key",StringComparison.OrdinalIgnoreCase)||String.Equals(leaf,".codex",StringComparison.OrdinalIgnoreCase)||String.Equals(leaf,".env",StringComparison.OrdinalIgnoreCase)||String.Equals(leaf,"credentials",StringComparison.OrdinalIgnoreCase)))throw new InvalidDataException("protected user data");
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
        return new CcodGenerationReclamationSnapshotV1(manifest==null?null:ReadText(manifest.Stream),fileRecords.ToArray(),directoryPaths.ToArray());
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
        if(runtimeParent!=null)ValidateDirectoryIdentity(runtimeParent,runtimeParentPath);
        foreach(Pin ancestor in residueAncestors)ValidateDirectoryIdentity(ancestor,ancestor.Path);
        ValidateDirectoryIdentity(selectedRoot,selectedPath);
        if(installRoot.Volume!=selectedRoot.Volume||(runtimeParent!=null&&runtimeParent.Volume!=selectedRoot.Volume))throw new InvalidDataException("selected root volume ancestry changed");
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
        for(int index=residueAncestors.Count-1;index>=0;index--){try{residueAncestors[index].Dispose();}catch{}}
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
    param([Parameter(Mandatory)][string]$ProjectVersion,[Parameter(Mandatory)][object[]]$Records,[Parameter(Mandatory)][string]$Nonce,[switch]$LegacyLiteralSeparators)
    if($ProjectVersion-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,45}$'-or$Nonce-cnotmatch'^[0-9a-f]{32}$'){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest identity components are invalid' $ProjectVersion};$lines=[Collections.Generic.List[string]]::new();foreach($record in $Records){$line=if($LegacyLiteralSeparators){'{0}`t{1}`t{2}'-f$record.path,[int64]$record.length,$record.sha256}else{"{0}`t{1}`t{2}"-f$record.path,[int64]$record.length,$record.sha256};$lines.Add($line)};$sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines-join"`n")))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};'{0}-{1}-{2}'-f$ProjectVersion,$digest.Substring(0,16),$Nonce
}

function Assert-CcodGenerationReclamationSnapshot {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)][string]$ExpectedManifestSha256,[switch]$AllowLegacy2521)
    $files=@($Snapshot.Files);$manifestFile=@($files|Where-Object{$_.Path-ceq'manifest.json'});if($manifestFile.Count-ne1-or[string]$manifestFile[0].Sha256-cne$ExpectedManifestSha256){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest hash does not match the durable binding' $RuntimeId}
    try{$json=[string]$Snapshot.ManifestText;if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $json)){throw 'duplicate properties'};$manifest=$json|ConvertFrom-Json -ErrorAction Stop}catch{Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest JSON is malformed or ambiguous' $RuntimeId}
    if(-not(Test-CcodGenerationReclamationExactProperties $manifest @('schemaVersion','projectVersion','runtimeId','files'))-or$manifest.schemaVersion-isnot[int]-or$manifest.schemaVersion-ne1-or$manifest.projectVersion-isnot[string]-or$manifest.runtimeId-isnot[string]-or$manifest.runtimeId-cne$RuntimeId-or$null-eq$manifest.files){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest header is invalid' $RuntimeId}
    $records=[Collections.Generic.List[object]]::new();$previous=$null;foreach($record in @($manifest.files)){$validated=ConvertTo-CcodGenerationReclamationRecord $record;if($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,$validated.path)-ge0){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest records are not strictly ordered' $RuntimeId};$previous=$validated.path;$records.Add($validated)}
    $match=[regex]::Match($RuntimeId,'^(?<version>[A-Za-z0-9][A-Za-z0-9._-]{0,45})-(?<digest>[0-9a-f]{16})-(?<nonce>[0-9a-f]{32})$')
    $legacy=$AllowLegacy2521-and$manifest.projectVersion-ceq'2.5.21'-and$RuntimeId-cmatch'^2\.5\.21-[0-9a-f]{16}\z'
    if($legacy){
        $suffix='-'+('0'*32);$canonical=Get-CcodGenerationReclamationRuntimeId -ProjectVersion '2.5.21' -Records $records.ToArray() -Nonce ('0'*32) -LegacyLiteralSeparators
        if($canonical.Substring(0,$canonical.Length-$suffix.Length)-cne$RuntimeId){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Legacy manifest digest does not match its exact runtime ID' $RuntimeId}
    }elseif(-not$match.Success-or$match.Groups['version'].Value-cne$manifest.projectVersion-or(Get-CcodGenerationReclamationRuntimeId -ProjectVersion $manifest.projectVersion -Records $records.ToArray() -Nonce $match.Groups['nonce'].Value)-cne$RuntimeId){Throw-CcodGenerationReclamationError 'CCOD_GENERATION_RECLAMATION_INVALID' 'Pinned manifest is not bound to the selected runtime ID' $RuntimeId}
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

function Read-CcodProductResidueText {
    param([Parameter(Mandatory)]$Native,[Parameter(Mandatory)][string]$Path)
    if($Native-is[Collections.IDictionary]){
        if(-not$Native.Contains($Path)-or$Native[$Path]-isnot[string]){throw 'cleanup evidence text is missing'}
        return [string]$Native[$Path]
    }
    return Invoke-CcodGenerationReclamationMethod -Runtime $Native -Name ReadFileText -Arguments @($Path)
}

function Read-CcodProductResidueJson {
    param([Parameter(Mandatory)]$Native,[Parameter(Mandatory)][string]$Path)
    $text=Read-CcodProductResidueText -Native $Native -Path $Path
    if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $text)){throw 'ambiguous product state'}
    $value=$text|ConvertFrom-Json -ErrorAction Stop
    if($value-isnot[pscustomobject]-or$null-eq$value.PSObject.Properties['schemaVersion']-or
       ($value.schemaVersion-isnot[int]-and$value.schemaVersion-isnot[long])-or$value.schemaVersion-lt1-or$value.schemaVersion-gt3){throw 'unknown product state format'}
    return $value
}

function Assert-CcodProductResidueSnapshot {
    param([Parameter(Mandatory)]$Native,[Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$SelectedRuntimeId,[Parameter(Mandatory)][uint64]$ExpectedEpoch)
    $epoch=Read-CcodProductResidueJson -Native $Native -Path 'state/lifecycle-epoch.json'
    if(-not(Test-CcodGenerationReclamationExactProperties $epoch @('schemaVersion','epoch'))-or
       ($epoch.epoch-isnot[int]-and$epoch.epoch-isnot[long])-or$epoch.epoch-lt0-or[uint64]$epoch.epoch-ne$ExpectedEpoch){throw 'product residue epoch changed'}
    $knownFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$knownFiles.Add('state/lifecycle-epoch.json')
    foreach($directory in @('runtime','state','logs','state/active-generation','state/lifecycle','state/lifecycle/receipts','state/lifecycle/inbox','state/workers')){[void]$expectedDirectories.Add($directory)}
    $pointers=[Collections.Generic.List[object]]::new()
    foreach($file in $Snapshot.Files){
        $path=[string]$file.Path
        if($path-cmatch'^state/active-generation/([0-9]{20})\.json\z'){
            $number=[uint64]$matches[1];$pointer=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $pointer @('schemaVersion','generation','activeRuntime','previousGeneration'))-or
               $pointer.schemaVersion-ne1-or$number-ne[uint64]($pointers.Count+1)-or
               ($pointer.generation-isnot[int]-and$pointer.generation-isnot[long])-or$pointer.generation-ne$number-or
               ($pointer.previousGeneration-isnot[int]-and$pointer.previousGeneration-isnot[long])-or$pointer.previousGeneration-ne($number-1)-or
               $pointer.activeRuntime-isnot[string]-or$pointer.activeRuntime-cnotmatch'^2\.[0-9]+\.[0-9]+-[0-9a-f]{16}(?:-[0-9a-f]{32})?\z'){throw 'product selector invalid'}
            $pointers.Add($pointer);[void]$knownFiles.Add($path)
        }
    }
    if($pointers.Count-eq0-or$pointers[$pointers.Count-1].activeRuntime-cne$SelectedRuntimeId){throw 'product residue selector changed'}
    $retainedIds=@($Snapshot.Directories|Where-Object {$_-cmatch'^runtime/[^/]+\z'}|ForEach-Object {$_.Substring(8)})
    foreach($runtimeId in $retainedIds){
        if($runtimeId-ceq$SelectedRuntimeId){throw 'selected generation was not reclaimed'}
        $prefix='runtime/'+$runtimeId+'/'
        $manifestFile=@($Snapshot.Files|Where-Object {$_.Path-ceq($prefix+'manifest.json')})
        if($manifestFile.Count-ne1){throw 'retained generation manifest is missing'}
        $manifestText=Read-CcodProductResidueText -Native $Native -Path ($prefix+'manifest.json')
        $relativeFiles=@($Snapshot.Files|Where-Object {$_.Path.StartsWith($prefix,[StringComparison]::Ordinal)}|ForEach-Object {[pscustomobject]@{Path=$_.Path.Substring($prefix.Length);Length=$_.Length;Sha256=$_.Sha256}})
        $relativeDirectories=@($Snapshot.Directories|Where-Object {$_.StartsWith($prefix,[StringComparison]::Ordinal)}|ForEach-Object {$_.Substring($prefix.Length)})
        [void](Assert-CcodGenerationReclamationSnapshot -Snapshot ([pscustomobject]@{Files=$relativeFiles;Directories=$relativeDirectories;ManifestText=$manifestText}) -RuntimeId $runtimeId -ExpectedManifestSha256 $manifestFile[0].Sha256 -AllowLegacy2521)
        [void]$expectedDirectories.Add('runtime/'+$runtimeId)
        foreach($file in $relativeFiles){[void]$knownFiles.Add($prefix+$file.Path)}
        foreach($directory in $relativeDirectories){[void]$expectedDirectories.Add($prefix+$directory)}
    }
    $stateFields=@{
        'settings.json'=@('schemaVersion','automationEnabled','candidateCompatibleOptIn','nodeCandidates','updatedAtUtc')
        'status.json'=@('schemaVersion','session')
        'verified-packages.json'=@('schemaVersion','packages')
        'transition.json'=@('schemaVersion','activeTransaction')
        'ui-preferences.json'=@('schemaVersion','languageMode','updatedAtUtc')
    }
    $transactionFields=@('schemaVersion','transactionId','oldRuntimeId','oldGeneration','oldManifestSha256','newRuntimeId','newGeneration','newManifestSha256','sealedPackageSha256','ownedObjectNames','phase','errorCode')
    $installPhases=@('Prepared','PackageVerified','RuntimeStaged','PreviousProtectionStopped','RuntimePromoted','PointerCommitted','StableShellCommitted','ProtectionReady','Ready')
    $activationFields=@('schemaVersion','activationId','phase','runtimeId','previousRuntimeId','startedAtUtc','updatedAtUtc','ready','errorCode')
    $activationPhases=@('StoppingPreviousRuntime','InstallingRuntime','ActivatingRuntime','StartingProtection','Ready','Failed')
    $readyRecords=@{}
    foreach($file in $Snapshot.Files|Where-Object {$_.Path-cmatch'^state/install-transactions/[0-9]{20}\.08\.Ready\.[0-9a-f-]{36}\.json\z'}){
        $record=Read-CcodProductResidueJson -Native $Native -Path $file.Path
        if(-not(Test-CcodGenerationReclamationExactProperties $record $transactionFields)-or$record.phase-cne'Ready'-or$record.newRuntimeId-isnot[string]){throw 'invalid Ready transaction'}
        $readyRecords[$record.transactionId]=$record
    }
    foreach($file in $Snapshot.Files){
        $path=[string]$file.Path
        if($knownFiles.Contains($path)){continue}
        if($path-cmatch'^logs/(install|session)\.log(?:\.(?:[1-9]|10))?\z'){
            $kind=$matches[1]
            if($file.Length-gt2097152){throw 'product diagnostic exceeds its writer limit'}
            $text=Read-CcodProductResidueText -Native $Native -Path $path
            foreach($line in @($text-split'\r?\n'|Where-Object {$_-cne''})){
                if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $line)){throw 'ambiguous product diagnostic'}
                $record=$line|ConvertFrom-Json -ErrorAction Stop
                $fields=if($kind-ceq'install'){@('schemaVersion','timestampUtc','component','stage','code','outcome')}else{@('schemaVersion','timestampUtc','action','transactionId','stage','code')}
                if($kind-ceq'session'-and$record.schemaVersion-eq2){$fields+=@('reason')}
                if(-not(Test-CcodGenerationReclamationExactProperties $record $fields)-or$record.schemaVersion-isnot[int]-or$record.schemaVersion-notin@(1,2)-or
                   $record.stage-isnot[string]-or$record.code-isnot[string]-or$record.code-cnotmatch'^CCOD_[A-Z0-9_]+\z'-or$record.timestampUtc-isnot[string]){throw 'unknown product diagnostic contract'}
                if($kind-ceq'install'-and($record.schemaVersion-ne1-or$record.component-cne'Install'-or$record.outcome-isnot[string])){throw 'unknown install diagnostic contract'}
                if($kind-ceq'session'-and$null-ne$record.action-and@('Inspect','Close','Apply','RepairRenderer','Recover')-cnotcontains$record.action){throw 'unknown session diagnostic action'}
                [void][DateTime]::ParseExact($record.timestampUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            }
            [void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/lifecycle/receipts/([0-9a-f-]{36})\.json\z'){
            $id=$matches[1];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            $fields=@('schemaVersion','transactionId','kind','origin','runtimeId','runtimeGeneration','leaseEpoch','ownerIdentity','logonIdentity','phase','createdAtUtc','updatedAtUtc','launchRequestedAtUtc','manualLaunchExpiresAtUtc','automaticLaunchAttempts','error')
            if(-not(Test-CcodGenerationReclamationExactProperties $value $fields)-or$value.schemaVersion-ne1-or$value.transactionId-cne$id-or
               @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade')-cnotcontains$value.phase-or
               @($pointers|Where-Object {$_.activeRuntime-ceq$value.runtimeId}).Count-eq0){throw 'lifecycle receipt is not a completed installed operation'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/lifecycle/inbox/([0-9a-f-]{36})\.receipt\.json\z'){
            $id=$matches[1];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','submissionId','accepted','transactionId','errorCode','completedAtUtc'))-or$value.schemaVersion-ne1-or$value.submissionId-cne$id-or$value.accepted-isnot[bool]-or
               ($value.accepted-and($value.transactionId-isnot[string]-or$value.transactionId-cnotmatch'^[0-9a-f-]{36}\z'-or$null-ne$value.errorCode))){throw 'submission receipt is not exact'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-ceq'state/lifecycle/safe-exit-intent.json'){
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','logonIdentity','runtimeId','recoveryTransactionId','createdAtUtc'))-or$value.schemaVersion-ne1-or
               @($pointers|Where-Object {$_.activeRuntime-ceq$value.runtimeId}).Count-eq0-or$value.recoveryTransactionId-isnot[string]-or$value.recoveryTransactionId-cnotmatch'^[0-9a-f-]{36}\z'-or
               -not(Test-CcodGenerationReclamationExactProperties $value.logonIdentity @('authenticationId','userSid','sessionId'))){throw 'safe-exit marker is not an installed lifecycle record'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-ceq'state/transaction-completion.receipt.json'){
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','transactionId','disposition','terminalStage','completedAtUtc','state','archiveErrorId'))-or$value.schemaVersion-ne1-or
               @('Archived','ArchiveFailed')-cnotcontains$value.state-or@('Cancelled','Activated','Recovered','Closed')-cnotcontains$value.disposition){throw 'transition completion is not terminal'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^logs/transactions\.log(?:\.(?:[1-9]|10))?\z'){
            if($file.Length-gt2097152){throw 'transaction log exceeds its writer limit'}
            $text=Read-CcodProductResidueText -Native $Native -Path $path
            foreach($line in @($text-split'\r?\n'|Where-Object {$_-cne''})){
                if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $line)){throw 'ambiguous transaction diagnostic'}
                $record=$line|ConvertFrom-Json -ErrorAction Stop
                $fields=@('schemaVersion','transactionId','disposition','terminalStage','sourcePid','sourceCreationTimeUtc','specialPid','specialCreationTimeUtc','recoveryPid','recoveryCreationTimeUtc','appAsarSha256','runtimeId','completedAtUtc','archiveState')
                if(-not(Test-CcodGenerationReclamationExactProperties $record $fields)-or$record.schemaVersion-isnot[int]-or$record.schemaVersion-ne1-or$record.archiveState-cne'Archived'-or
                   @('Cancelled','Activated','Recovered','Closed')-cnotcontains$record.disposition-or@($pointers|Where-Object {$_.activeRuntime-ceq$record.runtimeId}).Count-eq0){throw 'unknown transaction archive contract'}
            }
            [void]$knownFiles.Add($path);continue
        }
        if($path-ceq'active.json'){
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','activeRuntime','previousRuntime','generation','updatedAtUtc'))-or
               $value.schemaVersion-ne2-or$value.activeRuntime-cnotmatch'^2\.5\.21-[0-9a-f]{16}\z'-or$pointers[0].activeRuntime-cne$value.activeRuntime-or
               @($retainedIds|Where-Object {$_-ceq$value.activeRuntime}).Count-ne1){throw 'legacy pointer is not bound to a retained installed generation'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-ceq'state/post-install-activation.json'){
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value $activationFields)-or$value.schemaVersion-ne1-or$value.phase-cne'Ready'-or$value.ready-isnot[bool]-or-not$value.ready-or
               $value.runtimeId-cnotmatch'^2\.5\.21-[0-9a-f]{16}\z'-or$pointers[0].activeRuntime-cne$value.runtimeId-or$null-ne$value.errorCode){throw 'legacy activation record is not an exact Ready record'}
            [void]$knownFiles.Add($path);continue
        }
        if(@('bootstrap.ps1','Uninstall-CodexControlOtherDevices.ps1')-ccontains$path){
            $relative=if($path-ceq'bootstrap.ps1'){'src/persistence/bootstrap.ps1'}else{$path}
            $matching=@($Snapshot.Files|Where-Object {$_.Path-ceq('runtime/'+$pointers[0].activeRuntime+'/'+$relative)-and$_.Length-eq$file.Length-and$_.Sha256-ceq$file.Sha256})
            if($pointers[0].activeRuntime-cnotmatch'^2\.5\.21-[0-9a-f]{16}\z'-or$matching.Count-ne1){throw 'stable legacy shell differs from verified generation'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-ceq'state/lifecycle-epoch.initialized.json'){
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if($value.schemaVersion-ne1-or-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion'))){throw 'epoch initialization record is not exact'}
            [void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^logs/supervisor\.log(?:\.(?:[1-9]|10))?\z'){
            if($file.Length-gt2097152){throw 'product log exceeds its writer limit'}
            $text=Read-CcodProductResidueText -Native $Native -Path $path
            foreach($line in @($text-split'\r?\n'|Where-Object {$_-cne''})){
                if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $line)){throw 'ambiguous supervisor diagnostic'}
                $record=$line|ConvertFrom-Json -ErrorAction Stop
                $fields=@('schemaVersion','timestampUtc','component','stage','code','outcome')
                if($record.stage-ceq'TrayAction'){$fields+=@('command','revision','status')}
                elseif($record.stage-ceq'TrayHostReady'){$fields+=@('runtimeId','hostPid','hostCreationTimeUtc','protocolMajor','capabilities')}
                $abandonedWarning=$record.stage-ceq'LeaseAcquire'-and$record.code-ceq'CCOD_SUPERVISOR_LEASE_ABANDONED'-and$record.outcome-ceq'Warning'
                if(-not(Test-CcodGenerationReclamationExactProperties $record $fields)-or$record.schemaVersion-isnot[int]-or$record.schemaVersion-ne1-or
                   $record.component-cne'Supervisor'-or$record.stage-isnot[string]-or$record.code-isnot[string]-or$record.code-cnotmatch'^CCOD_[A-Z0-9_]+\z'-or
                   $record.outcome-isnot[string]-or(@('Completed','Rejected','Failed','Ready')-cnotcontains$record.outcome-and-not$abandonedWarning)-or$record.timestampUtc-isnot[string]){throw 'unknown supervisor diagnostic contract'}
                [void][DateTime]::ParseExact($record.timestampUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            }
            [void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/install-initializations/(2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32})/([^/]+)\z'){
            $runtimeId=$matches[1];$leaf=$matches[2]
            if(-not$stateFields.ContainsKey($leaf)-or@($pointers|Where-Object {$_.activeRuntime-ceq$runtimeId}).Count-eq0){throw 'initialization baseline is not an installed generation'}
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if($value.schemaVersion-ne1-or-not(Test-CcodGenerationReclamationExactProperties $value $stateFields[$leaf])){throw 'initialization state members changed'}
            [void]$expectedDirectories.Add('state/install-initializations');[void]$expectedDirectories.Add('state/install-initializations/'+$runtimeId)
            [void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/install-transactions/([0-9]{20})\.([0-9]{2})\.([A-Za-z]+)\.([0-9a-f-]{36})\.json\z'){
            $generation=[uint64]$matches[1];$phaseIndex=[int]$matches[2];$phase=$matches[3];$id=$matches[4]
            $value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value $transactionFields)-or$value.newGeneration-ne$generation-or$value.phase-cne$phase-or$value.transactionId-cne$id-or
               $phaseIndex-ge$installPhases.Count-or$installPhases[$phaseIndex]-cne$phase-or-not$readyRecords.ContainsKey($id)-or$value.newRuntimeId-cne$readyRecords[$id].newRuntimeId){throw 'install transaction identity mismatch'}
            [void]$expectedDirectories.Add('state/install-transactions');[void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/activation-receipts/([0-9a-f-]{36})\.([A-Za-z]+)\.json\z'){
            $id=$matches[1];$phase=$matches[2];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value $activationFields)-or$value.activationId-cne$id-or$value.phase-cne$phase-or$activationPhases-cnotcontains$phase-or
               $value.ready-isnot[bool]-or$value.ready-ne($phase-ceq'Ready')-or($null-ne$value.runtimeId-and@($pointers|Where-Object {$_.activeRuntime-ceq$value.runtimeId}).Count-eq0)){throw 'activation receipt identity mismatch'}
            [void]$expectedDirectories.Add('state/activation-receipts');[void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/install-logs/([0-9]{1,19})\.([A-Za-z]+)\.[0-9a-f]{32}\.json\z'){
            $ticks=$matches[1];$stage=$matches[2];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','timestampUtc','component','stage','code','outcome'))-or
               $value.component-cne'Install'-or$value.stage-cne$stage-or$value.code-cnotmatch'^CCOD_[A-Z0-9_]+\z'-or
               [DateTime]::Parse($value.timestampUtc).Ticks.ToString()-cne$ticks){throw 'install log identity mismatch'}
            [void]$expectedDirectories.Add('state/install-logs');[void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/product-cleanup-fences/([0-9]{20})\.(Pending|Completed)\.([0-9a-f-]{36})\.json\z'){
            $attempt=$matches[1];$state=$matches[2];$id=$matches[3];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','transactionId','runtimeId','runtimeGeneration','manifestSha256','packageSha256','ownerPid','ownerCreationTimeUtc','ownerSid','state'))-or
               $value.transactionId-cne$id-or$value.state-cne$state-or-not$readyRecords.ContainsKey($id)-or$value.runtimeId-cne$readyRecords[$id].newRuntimeId-or$value.manifestSha256-cne$readyRecords[$id].newManifestSha256-or
               @($Snapshot.Files|Where-Object {$_.Path-ceq('state/product-cleanup-fences/'+$attempt+'.Completed.'+$id+'.json')}).Count-ne1){throw 'product cleanup fence is incomplete or changed'}
            [void]$expectedDirectories.Add('state/product-cleanup-fences');[void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/legacy-registration-migrations/([0-9]{20})\.([0-9a-f-]{36})\.json\z'){
            $generation=[uint64]$matches[1];$id=$matches[2];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value @('schemaVersion','transactionId','runtimeId','runtimeGeneration','manifestSha256','packageSha256','readyTransaction','appId','expectedInstallRoot','legacyPresent','legacyRegistration','profile','snapshot','expectedCurrentProof'))-or
               $value.transactionId-cne$id-or$value.runtimeGeneration-ne$generation-or-not$readyRecords.ContainsKey($id)-or$value.runtimeId-cne$readyRecords[$id].newRuntimeId-or
               $value.manifestSha256-cne$readyRecords[$id].newManifestSha256-or($value.readyTransaction|ConvertTo-Json -Depth 8 -Compress)-cne($readyRecords[$id]|ConvertTo-Json -Depth 8 -Compress)-or
               $value.appId-cne'{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}'){throw 'legacy migration record identity mismatch'}
            [void]$expectedDirectories.Add('state/legacy-registration-migrations');[void]$knownFiles.Add($path);continue
        }
        if($path-cmatch'^state/([^/]+)\z'-and$stateFields.ContainsKey($matches[1])){
            $leaf=$matches[1];$value=Read-CcodProductResidueJson -Native $Native -Path $path
            if(-not(Test-CcodGenerationReclamationExactProperties $value $stateFields[$leaf])){throw 'unrecognized product state members'}
            if($leaf-ceq'settings.json'-and$value.automationEnabled-cne$false){throw 'automation must be stopped'}
            if($leaf-ceq'status.json'-and$null-ne$value.session){throw 'active session remains'}
            if($leaf-ceq'transition.json'-and$null-ne$value.activeTransaction){throw 'active transition remains'}
            [void]$knownFiles.Add($path);continue
        }
        throw ('unrecognized product residue: '+$path)
    }
    foreach($directory in $Snapshot.Directories){if(-not$expectedDirectories.Contains([string]$directory)){throw ('unrecognized product directory: '+$directory)}}
}

function Remove-CcodVerifiedProductResidue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$SelectedRuntimeId,[Parameter(Mandatory)][uint64]$ExpectedEpoch,[string]$TransactionDirectory,[string]$TransactionId)
    $native=$null;$journal=$null
    try {
        $root=[IO.Path]::GetFullPath($InstallRoot)
        if($root-cne$InstallRoot-or[IO.Path]::GetFileName($root)-cne'CodexControlOtherDevices'-or
           $SelectedRuntimeId-cnotmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}\z'){throw 'product residue root or runtime identity'}
        Initialize-CcodGenerationReclamationRuntime
        $hasJournal=-not[string]::IsNullOrEmpty($TransactionDirectory)
        $planPath=$null;$planPresent=$false;$rootPresent=$false
        if($hasJournal){
            if($TransactionId-cnotmatch'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'){throw 'product cleanup transaction ID'}
            $expectedDirectory=Join-Path (Split-Path $root -Parent) ('CodexRemote-fix-uninstall/'+$TransactionId)
            if([IO.Path]::GetFullPath($TransactionDirectory)-cne[IO.Path]::GetFullPath($expectedDirectory)){throw 'product cleanup journal escaped its transaction'}
            $planPath=Join-Path $TransactionDirectory 'product-residue-plan.json'
            try {Get-Item -LiteralPath $planPath -Force -ErrorAction Stop|Out-Null;$planPresent=$true}catch [Management.Automation.ItemNotFoundException]{}
        }
        try {Get-Item -LiteralPath $root -Force -ErrorAction Stop|Out-Null;$rootPresent=$true}catch [Management.Automation.ItemNotFoundException]{}
        if($rootPresent){
            $native=Invoke-CcodGenerationReclamationStatic -Name OpenResidue -Arguments @($root)
            $snapshot=Invoke-CcodGenerationReclamationMethod -Runtime $native -Name Snapshot -Arguments @()
        }elseif(-not$planPresent){throw 'missing product root has no prior cleanup authority'}
        if(-not$planPresent){Assert-CcodProductResidueSnapshot -Native $native -Snapshot $snapshot -SelectedRuntimeId $SelectedRuntimeId -ExpectedEpoch $ExpectedEpoch}
        if($hasJournal){
            $journal=Invoke-CcodGenerationReclamationStatic -Name OpenJournal -Arguments @([IO.Path]::GetFullPath($TransactionDirectory))
            if($journal.Created){
                if($planPresent-or-not$rootPresent){throw 'cleanup journal changed at acquisition'}
                $evidence=@($snapshot.Files|Where-Object {$_.Path-ceq'active.json'-or$_.Path.StartsWith('state/',[StringComparison]::Ordinal)-or$_.Path.StartsWith('logs/',[StringComparison]::Ordinal)-or$_.Path.EndsWith('/manifest.json',[StringComparison]::Ordinal)}|ForEach-Object {[pscustomobject][ordered]@{path=[string]$_.Path;text=(Read-CcodProductResidueText -Native $native -Path $_.Path)}})
                $plan=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$TransactionId;installRoot=$root;runtimeId=$SelectedRuntimeId;epoch=$ExpectedEpoch;rootIdentity=(Invoke-CcodGenerationReclamationMethod -Runtime $native -Name RootIdentity -Arguments @());files=@($snapshot.Files|ForEach-Object {[pscustomobject][ordered]@{path=[string]$_.Path;length=[long]$_.Length;sha256=[string]$_.Sha256}});directories=@($snapshot.Directories);evidence=$evidence}
                $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($plan|ConvertTo-Json -Depth 8 -Compress))
                if($bytes.Length-gt4194304){throw 'cleanup journal bounds'}
                $journal.Stream.Write($bytes,0,$bytes.Length);$journal.Stream.Flush($true)
            }
            if($journal.Stream.Length-lt1-or$journal.Stream.Length-gt4194304){throw 'invalid cleanup journal length'}
            $journal.Stream.Position=0;$bytes=[byte[]]::new([int]$journal.Stream.Length);$read=0
            while($read-lt$bytes.Length){$count=$journal.Stream.Read($bytes,$read,$bytes.Length-$read);if($count-le0){throw 'incomplete cleanup journal'};$read+=$count}
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            if(-not(Test-CcodGenerationReclamationJsonHasNoDuplicateProperties $text)){throw 'ambiguous cleanup journal'}
            $plan=$text|ConvertFrom-Json -ErrorAction Stop
            if(-not(Test-CcodGenerationReclamationExactProperties $plan @('schemaVersion','transactionId','installRoot','runtimeId','epoch','rootIdentity','files','directories','evidence'))-or
               $plan.schemaVersion-isnot[int]-or$plan.schemaVersion-ne1-or$plan.transactionId-isnot[string]-or$plan.transactionId-cne$TransactionId-or$plan.installRoot-isnot[string]-or$plan.installRoot-cne$root-or$plan.runtimeId-isnot[string]-or$plan.runtimeId-cne$SelectedRuntimeId-or
               ($plan.epoch-isnot[int]-and$plan.epoch-isnot[long])-or$plan.epoch-ne$ExpectedEpoch-or
               $plan.rootIdentity-isnot[string]-or$plan.rootIdentity-cnotmatch'^[0-9]+-[0-9]+\z'-or$plan.files-isnot[array]-or$plan.directories-isnot[array]-or$plan.evidence-isnot[array]){throw 'cleanup journal binding changed'}
            $expected=@{};foreach($file in $plan.files){
                if(-not(Test-CcodGenerationReclamationExactProperties $file @('path','length','sha256'))-or$file.path-isnot[string]-or$expected.ContainsKey($file.path)-or$file.sha256-isnot[string]-or$file.sha256-cnotmatch'^[0-9a-f]{64}\z'-or
                   ($file.length-isnot[int]-and$file.length-isnot[long])-or$file.length-lt0){throw 'cleanup journal file identity'}
                $expected[$file.path]=$file
            }
            $texts=[ordered]@{};$sha=[Security.Cryptography.SHA256]::Create()
            try {foreach($entry in $plan.evidence){
                if(-not(Test-CcodGenerationReclamationExactProperties $entry @('path','text'))-or$entry.path-isnot[string]-or$entry.text-isnot[string]-or$texts.Contains($entry.path)-or-not$expected.ContainsKey($entry.path)){throw 'cleanup journal evidence identity'}
                $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($entry.text);$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
                if($bytes.LongLength-ne$expected[$entry.path].length-or$hash-cne$expected[$entry.path].sha256){throw 'cleanup journal evidence bytes changed'}
                $texts[$entry.path]=$entry.text
            }}finally{$sha.Dispose()}
            $savedSnapshot=[pscustomobject]@{Files=@($plan.files|ForEach-Object {[pscustomobject]@{Path=$_.path;Length=$_.length;Sha256=$_.sha256}});Directories=$plan.directories}
            Assert-CcodProductResidueSnapshot -Native $texts -Snapshot $savedSnapshot -SelectedRuntimeId $SelectedRuntimeId -ExpectedEpoch $ExpectedEpoch
            if(-not$rootPresent){return [pscustomobject][ordered]@{phase='Completed';result='Removed';fileCount=0}}
            if($plan.rootIdentity-cne(Invoke-CcodGenerationReclamationMethod -Runtime $native -Name RootIdentity -Arguments @())){throw 'product root identity changed after cleanup began'}
            foreach($file in $snapshot.Files){if(-not$expected.ContainsKey($file.Path)-or$expected[$file.Path].length-ne$file.Length-or$expected[$file.Path].sha256-cne$file.Sha256){throw 'product residue changed during retry'}}
            foreach($directory in $snapshot.Directories){if($plan.directories-cnotcontains$directory){throw 'product residue directory changed during retry'}}
        }
        [void](Invoke-CcodGenerationReclamationMethod -Runtime $native -Name Reclaim -Arguments @(-1,[int]$script:CcodProductResidueFailCommitAtForTest))
        try {Get-Item -LiteralPath $root -Force -ErrorAction Stop|Out-Null;throw 'product root remains'}catch [Management.Automation.ItemNotFoundException]{}
        return [pscustomobject][ordered]@{phase='Completed';result='Removed';fileCount=[int]$snapshot.Files.Count}
    } catch {
        Throw-CcodGenerationReclamationError 'CCOD_PRODUCT_RESIDUE_INVALID' ('Bounded product cleanup rejected: '+$_.Exception.Message) $InstallRoot
    } finally {if($null-ne$journal){$journal.Dispose()};if($null-ne$native){$native.Dispose()}}
}

Export-ModuleMember -Function Remove-CcodVerifiedGenerationTree,Remove-CcodVerifiedProductResidue
