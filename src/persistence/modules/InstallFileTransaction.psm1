Set-StrictMode -Version Latest

$script:CcodTransactions = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()
$script:CcodScopes = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()

function Throw-CcodInstallFileError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Initialize-CcodInstallRuntime {
    if ($null -ne ('CcodInstallCapabilityMarker' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CcodInstallCapabilityMarker
{
    private CcodInstallCapabilityMarker() { }
    public static int CapabilityAbi { get { return 1; } }
}

internal sealed class CcodInstallRuntime : IDisposable
{
    private const uint READ = 0x80000000, WRITE = 0x40000000, DELETE = 0x00010000, SYNC = 0x00100000;
    private const uint READ_ATTRIBUTES = 0x80, LIST_DIRECTORY = 0x1, ADD_FILE = 0x2, ADD_SUBDIRECTORY = 0x4;
    private const uint SHARE_READ = 1, SHARE_WRITE = 2, SHARE_DELETE = 4;
    private const uint OPEN = 1, CREATE = 2;
    private const uint DIRECTORY = 1, WRITE_THROUGH = 2, SYNC_IO = 0x20, NON_DIRECTORY = 0x40, BACKUP_INTENT = 0x4000, OPEN_REPARSE = 0x200000;
    private const uint FLAG_BACKUP = 0x02000000, FLAG_REPARSE = 0x00200000;
    private const uint OPEN_EXISTING = 3, OBJ_CASE_INSENSITIVE = 0x40, ATTR_DIRECTORY = 0x10, ATTR_REPARSE = 0x400;
    private const int FileRenameInformation = 10, FileStreamInfo = 7, FileDirectoryInformation = 1;
    private const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);

    [StructLayout(LayoutKind.Sequential)] private struct UNICODE_STRING { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] private struct IO_STATUS_BLOCK { public IntPtr Status; public UIntPtr Information; }
    [StructLayout(LayoutKind.Sequential)] private struct FILETIME_NATIVE { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] private struct FILE_INFO
    {
        public uint FileAttributes; public FILETIME_NATIVE CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FILE_INFO info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder buffer,uint length,uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int infoClass,IntPtr info,uint size);
    [DllImport("ntdll.dll")] private static extern int NtCreateFile(out IntPtr handle,uint access,ref OBJECT_ATTRIBUTES attributes,out IO_STATUS_BLOCK io,IntPtr allocationSize,uint fileAttributes,uint share,uint disposition,uint options,IntPtr ea,uint eaLength);
    [DllImport("ntdll.dll")] private static extern int NtQueryDirectoryFile(SafeFileHandle handle,IntPtr evt,IntPtr apc,IntPtr context,out IO_STATUS_BLOCK io,IntPtr info,uint length,int infoClass,bool single,IntPtr name,bool restart);
    [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle handle,out IO_STATUS_BLOCK io,IntPtr info,uint length,int infoClass);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);

    private sealed class Pin : IDisposable
    {
        internal readonly object Token = new object();
        internal readonly Pin Parent; internal string Leaf, Path;
        internal readonly bool Directory, Owned; internal SafeFileHandle Handle; internal FileStream Stream;
        internal readonly uint Volume; internal readonly ulong Index; internal bool Closed, Sealed, Manifest;
        internal Pin(Pin parent,string leaf,string path,bool directory,bool owned,SafeFileHandle handle,FileStream stream,FILE_INFO info)
        { Parent=parent;Leaf=leaf;Path=path;Directory=directory;Owned=owned;Handle=handle;Stream=stream;Volume=info.VolumeSerialNumber;Index=((ulong)info.FileIndexHigh<<32)|info.FileIndexLow; }
        internal SafeFileHandle Native { get { return Stream != null ? Stream.SafeFileHandle : Handle; } }
        public void Dispose() { if(Closed)return;Closed=true;if(Stream!=null)Stream.Dispose();else if(Handle!=null)Handle.Dispose(); }
    }

    private sealed class ReferenceComparer : IEqualityComparer<object>
    { internal static readonly ReferenceComparer Instance=new ReferenceComparer();public new bool Equals(object x,object y){return Object.ReferenceEquals(x,y);}public int GetHashCode(object x){return RuntimeHelpers.GetHashCode(x);} }
    private sealed class OpenResult { internal SafeFileHandle Handle; internal bool Created; internal OpenResult(SafeFileHandle handle,bool created){Handle=handle;Created=created;} }

    private readonly string installRoot; private readonly Pin root, runtimeParent;
    private readonly Dictionary<object,Pin> pins = new Dictionary<object,Pin>(ReferenceComparer.Instance);
    private readonly Dictionary<string,Pin> names = new Dictionary<string,Pin>(StringComparer.OrdinalIgnoreCase);
    private readonly List<FileStream> externalStreams = new List<FileStream>();
    private bool disposed;

    private CcodInstallRuntime(string installRoot,Pin root,Pin runtimeParent)
    { this.installRoot=installRoot;this.root=root;this.runtimeParent=runtimeParent;AddPin(root);AddPin(runtimeParent); }

    internal static object Open(string path,string runtimeId,out CcodInstallRuntime runtime)
    {
        runtime=null;string full=Path.GetFullPath(path).TrimEnd('\\');SafeFileHandle rootHandle=OpenAbsoluteDirectory(full,true);Pin rootPin=null,runtimePin=null;
        try
        {
            rootPin=ValidateDirectoryPin(null,"",full,false,rootHandle);rootHandle=null;
            OpenResult runtimeResult;
            try { runtimeResult=OpenRelative(rootPin.Native,"runtime",LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,CREATE,DIRECTORY|BACKUP_INTENT); }
            catch(Win32Exception exception) { if(exception.NativeErrorCode!=80&&exception.NativeErrorCode!=183)throw;runtimeResult=OpenRelative(rootPin.Native,"runtime",LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT); }
            try { runtimePin=ValidateDirectoryPin(rootPin,"runtime",Path.Combine(full,"runtime"),false,runtimeResult.Handle);runtimeResult.Handle=null; }
            finally { if(runtimeResult.Handle!=null)runtimeResult.Handle.Dispose(); }
            OpenResult generationResult=OpenRelative(runtimePin.Native,runtimeId,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,SHARE_READ,CREATE,DIRECTORY|BACKUP_INTENT);
            try
            {
                Pin generation=ValidateDirectoryPin(runtimePin,runtimeId,Path.Combine(runtimePin.Path,runtimeId),true,generationResult.Handle);generationResult.Handle=null;
                runtime=new CcodInstallRuntime(full,rootPin,runtimePin);rootPin=null;runtimePin=null;runtime.AddPin(generation);return generation.Token;
            }
            finally { if(generationResult.Handle!=null)generationResult.Handle.Dispose(); }
        }
        catch { if(runtimePin!=null)runtimePin.Dispose();if(rootPin!=null)rootPin.Dispose();if(rootHandle!=null)rootHandle.Dispose();throw; }
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object CreateDirectory(object parentToken,string leaf)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);OpenResult result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,SHARE_READ,CREATE,DIRECTORY|BACKUP_INTENT);
        try { Pin pin=ValidateDirectoryPin(parent,leaf,Path.Combine(parent.Path,leaf),true,result.Handle);result.Handle=null;AddPin(pin);return pin.Token; }
        finally { if(result.Handle!=null)result.Handle.Dispose(); }
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object Copy(object parentToken,string leaf,string source,long expectedLength,string expectedSha)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);string full=Path.GetFullPath(source);
        SafeFileHandle sourceHandle=CreateFileW(full,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,IntPtr.Zero,OPEN_EXISTING,FLAG_REPARSE,IntPtr.Zero);
        if(sourceHandle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());FileStream sourceStream=null,destinationStream=null;OpenResult destinationResult=null;
        try
        {
            FILE_INFO sourceInfo=Info(sourceHandle);ValidatePlain(sourceInfo,sourceHandle);if(!SamePath(FinalPath(sourceHandle),full))throw new InvalidDataException("source path changed");
            sourceStream=new FileStream(sourceHandle,FileAccess.Read,65536,false);sourceHandle=null;
            if(sourceStream.Length!=expectedLength||Sha(sourceStream)!=expectedSha)throw new InvalidDataException("source mismatch");sourceStream.Position=0;
            destinationResult=OpenRelative(parent.Native,leaf,READ|WRITE|SYNC,SHARE_READ,CREATE,NON_DIRECTORY|WRITE_THROUGH);
            destinationStream=new FileStream(destinationResult.Handle,FileAccess.ReadWrite,65536,false);destinationResult.Handle=null;
            FILE_INFO destinationInfo=Info(destinationStream.SafeFileHandle);ValidatePlain(destinationInfo,destinationStream.SafeFileHandle);
            Pin destination=new Pin(parent,leaf,Path.Combine(parent.Path,leaf),false,true,null,destinationStream,destinationInfo);destinationStream=null;
            sourceStream.CopyTo(destination.Stream);destination.Stream.Flush(true);
            if(destination.Stream.Length!=expectedLength||Sha(destination.Stream)!=expectedSha)throw new InvalidDataException("destination mismatch");destination.Sealed=true;MakeReadable(destination);AddPin(destination);externalStreams.Add(sourceStream);sourceStream=null;return destination.Token;
        }
        finally { if(sourceStream!=null)sourceStream.Dispose();if(sourceHandle!=null)sourceHandle.Dispose();if(destinationStream!=null)destinationStream.Dispose();if(destinationResult!=null&&destinationResult.Handle!=null)destinationResult.Handle.Dispose(); }
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object Write(object parentToken,string leaf,byte[] bytes,bool manifest)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);OpenResult result=OpenRelative(parent.Native,leaf,READ|WRITE|DELETE|SYNC,SHARE_READ,CREATE,NON_DIRECTORY|WRITE_THROUGH);FileStream stream=null;
        try
        {
            stream=new FileStream(result.Handle,FileAccess.ReadWrite,65536,false);result.Handle=null;FILE_INFO info=Info(stream.SafeFileHandle);ValidatePlain(info,stream.SafeFileHandle);Pin pin=new Pin(parent,leaf,Path.Combine(parent.Path,leaf),false,true,null,stream,info);stream=null;
            pin.Stream.Write(bytes,0,bytes.Length);pin.Stream.Flush(true);string sha=Sha(pin.Stream);if(pin.Stream.Length!=bytes.LongLength)throw new InvalidDataException("destination mismatch");pin.Sealed=true;pin.Manifest=manifest;if(manifest)MakeReadable(pin);AddPin(pin);return new object[]{pin.Token,pin.Stream.Length,sha};
        }
        finally { if(stream!=null)stream.Dispose();if(result.Handle!=null)result.Handle.Dispose(); }
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object CommitPointer(object generationToken,ulong previousGeneration,string runtimeId,byte[] bytes)
    {
        Pin generation=Require(generationToken,true);ValidateCurrent(generation);if(!Object.ReferenceEquals(generation.Parent,runtimeParent)||!String.Equals(generation.Leaf,runtimeId,StringComparison.Ordinal))throw new InvalidDataException("transaction scope");
        Pin manifest=null;if(!names.TryGetValue(Key(generation,"manifest.json"),out manifest)||!manifest.Manifest||!manifest.Sealed)throw new InvalidDataException("manifest missing");ValidateCurrent(manifest);
        Pin state=OpenOrCreateDirectory(root,"state"),pointer=OpenOrCreateDirectory(state,"active-generation");if(CurrentPointerGeneration(pointer)!=previousGeneration)throw new InvalidOperationException("pointer generation exists");string leaf=(previousGeneration+1).ToString("D20")+".json";return WriteAtomic(pointer,leaf,bytes);
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object Retire(object generationToken,string runtimeId,string retiredLeaf,byte[] record)
    {
        Pin generation=Require(generationToken,true);ValidateCurrent(generation);if(!Object.ReferenceEquals(generation.Parent,runtimeParent)||!String.Equals(generation.Leaf,runtimeId,StringComparison.Ordinal)||!generation.Owned)throw new InvalidDataException("generation not owned");
        ValidateOwnedTree(generation);Pin retired=OpenOrCreateDirectory(root,"retired"),state=OpenOrCreateDirectory(root,"state"),retirements=OpenOrCreateDirectory(state,"retirements");ReleaseDescendants(generation);int error=Rename(generation.Native,retired.Native,retiredLeaf);if(error!=0)throw new Win32Exception(error);MoveDirectoryPin(generation,retired,retiredLeaf,Path.Combine(retired.Path,retiredLeaf));
        WriteAtomic(retirements,retiredLeaf+".json",record);return generation.Token;
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal void Close()
    { if(disposed)return;disposed=true;foreach(FileStream stream in externalStreams)stream.Dispose();externalStreams.Clear();List<Pin> all=new List<Pin>(pins.Values);for(int i=all.Count-1;i>=0;i--)all[i].Dispose();pins.Clear();names.Clear(); }
    public void Dispose(){Close();}

    private Pin OpenOrCreateDirectory(Pin parent,string leaf)
    {
        Pin existing;if(names.TryGetValue(Key(parent,leaf),out existing)){ValidateCurrent(existing);return existing;}
        OpenResult result;
        try { result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,CREATE,DIRECTORY|BACKUP_INTENT); }
        catch(Win32Exception exception) { if(exception.NativeErrorCode!=80&&exception.NativeErrorCode!=183)throw;result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT); }
        try { Pin pin=ValidateDirectoryPin(parent,leaf,Path.Combine(parent.Path,leaf),result.Created,result.Handle);result.Handle=null;AddPin(pin);return pin; }
        finally { if(result.Handle!=null)result.Handle.Dispose(); }
    }

    private void ValidateOwnedTree(Pin directory)
    {
        ValidateCurrent(directory);foreach(string leaf in Enumerate(directory.Native)){Pin child;if(!names.TryGetValue(Key(directory,leaf),out child)||!child.Owned)throw new InvalidDataException("unknown leaf");ValidateCurrent(child);if(child.Directory)ValidateOwnedTree(child);else if(!child.Sealed)throw new InvalidDataException("unsealed leaf");}
    }
    private object WriteAtomic(Pin parent,string leaf,byte[] bytes)
    {
        string temporary=".ccod."+Guid.NewGuid().ToString("N")+".tmp";object[] result=(object[])Write(parent.Token,temporary,bytes,false);Pin pin=Require(result[0],false);int error=Rename(pin.Native,parent.Native,leaf);if(error!=0)throw new Win32Exception(error);names.Remove(Key(parent,temporary));pin.Leaf=leaf;pin.Path=Path.Combine(parent.Path,leaf);names.Add(Key(parent,leaf),pin);MakeReadable(pin);return result;
    }
    private static ulong CurrentPointerGeneration(Pin pointer)
    {
        ulong maximum=0;foreach(string leaf in Enumerate(pointer.Native)){if(leaf.StartsWith(".ccod.",StringComparison.OrdinalIgnoreCase)&&leaf.EndsWith(".tmp",StringComparison.OrdinalIgnoreCase))continue;if(leaf.Length!=25||!leaf.EndsWith(".json",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("unknown pointer leaf");ulong value;if(!UInt64.TryParse(leaf.Substring(0,20),out value)||value==0)throw new InvalidDataException("unknown pointer leaf");if(value>maximum)maximum=value;}return maximum;
    }
    private void ReleaseDescendants(Pin directory)
    {
        foreach(Pin pin in pins.Values)if(!pin.Closed&&!Object.ReferenceEquals(pin,directory)&&pin.Path.StartsWith(directory.Path.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))pin.Dispose();
    }
    private Pin Require(object token,bool directory){if(disposed)throw new ObjectDisposedException("transaction");Pin pin;if(token==null||!pins.TryGetValue(token,out pin)||pin.Closed||pin.Directory!=directory)throw new InvalidDataException("invalid capability");return pin;}
    private void AddPin(Pin pin){pins.Add(pin.Token,pin);if(pin.Parent!=null)names.Add(Key(pin.Parent,pin.Leaf),pin);}
    private static string Key(Pin parent,string leaf){return parent.Index.ToString("x16")+"|"+leaf.ToLowerInvariant();}
    private void MoveDirectoryPin(Pin directory,Pin parent,string leaf,string path){string oldPath=directory.Path;names.Remove(Key(directory.Parent,directory.Leaf));directory.Leaf=leaf;directory.Path=path;names.Add(Key(parent,leaf),directory);string prefix=oldPath.TrimEnd('\\')+"\\";foreach(Pin pin in pins.Values)if(!Object.ReferenceEquals(pin,directory)&&pin.Path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase))pin.Path=path+"\\"+pin.Path.Substring(prefix.Length);}
    private static Pin ValidateDirectoryPin(Pin parent,string leaf,string path,bool owned,SafeFileHandle handle){FILE_INFO info=Info(handle);if(!IsDirectory(info)||(info.FileAttributes&ATTR_REPARSE)!=0||!OnlyDefaultStream(handle)||!SamePath(FinalPath(handle),path))throw new InvalidDataException("directory invalid");return new Pin(parent,leaf,path,true,owned,handle,null,info);}
    private static void MakeReadable(Pin pin){OpenResult bridge=OpenRelative(pin.Parent.Native,pin.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE|SHARE_DELETE,OPEN,NON_DIRECTORY);FILE_INFO bridgeInfo=Info(bridge.Handle);if(bridgeInfo.VolumeSerialNumber!=pin.Volume||(((ulong)bridgeInfo.FileIndexHigh<<32)|bridgeInfo.FileIndexLow)!=pin.Index){bridge.Handle.Dispose();throw new InvalidDataException("pin changed");}pin.Stream.Dispose();pin.Stream=null;OpenResult strict=OpenRelative(pin.Parent.Native,pin.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);bridge.Handle.Dispose();pin.Stream=new FileStream(strict.Handle,FileAccess.Read,65536,false);strict.Handle=null;}
    private static SafeFileHandle OpenAbsoluteDirectory(string path,bool allowWrite){uint access=LIST_DIRECTORY|READ_ATTRIBUTES|SYNC;if(allowWrite)access|=ADD_FILE|ADD_SUBDIRECTORY;SafeFileHandle handle=CreateFileW(path,access,SHARE_READ|SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,FLAG_BACKUP|FLAG_REPARSE,IntPtr.Zero);if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());return handle;}
    private static void ValidateCurrent(Pin pin){FILE_INFO info=Info(pin.Native);if(info.VolumeSerialNumber!=pin.Volume||(((ulong)info.FileIndexHigh<<32)|info.FileIndexLow)!=pin.Index||IsDirectory(info)!=pin.Directory||(info.FileAttributes&ATTR_REPARSE)!=0||!SamePath(FinalPath(pin.Native),pin.Path))throw new InvalidDataException("pin changed");if(!OnlyDefaultStream(pin.Native))throw new InvalidDataException("alternate stream");if(!pin.Directory&&info.NumberOfLinks!=1)throw new InvalidDataException("multi-link");}
    private static void ValidatePlain(FILE_INFO info,SafeFileHandle handle){if(IsDirectory(info))throw new InvalidDataException("file type");if((info.FileAttributes&ATTR_REPARSE)!=0)throw new InvalidDataException("reparse leaf");if(info.NumberOfLinks!=1)throw new InvalidDataException("multi-link");if(!OnlyDefaultStream(handle))throw new InvalidDataException("alternate stream");}
    private static bool IsDirectory(FILE_INFO info){return(info.FileAttributes&ATTR_DIRECTORY)!=0;}
    private static FILE_INFO Info(SafeFileHandle handle){FILE_INFO info;if(handle==null||handle.IsClosed||!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());return info;}
    private static string Sha(FileStream stream){long position=stream.Position;using(SHA256 hash=SHA256.Create()){stream.Position=0;string value=BitConverter.ToString(hash.ComputeHash(stream)).Replace("-","").ToLowerInvariant();stream.Position=position;return value;}}
    private static string FinalPath(SafeFileHandle handle){StringBuilder buffer=new StringBuilder(512);uint length=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,0);if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());if(length>=buffer.Capacity){buffer.Capacity=(int)length+1;length=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,0);if(length==0||length>=buffer.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());}string path=buffer.ToString();if(path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return@"\\"+path.Substring(8);if(path.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return path.Substring(4);return path;}
    private static bool SamePath(string first,string second){return String.Equals(Path.GetFullPath(first).TrimEnd('\\'),Path.GetFullPath(second).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);}
    private static bool OnlyDefaultStream(SafeFileHandle handle){IntPtr buffer=Marshal.AllocHGlobal(65536);try{if(!GetFileInformationByHandleEx(handle,FileStreamInfo,buffer,65536)){int error=Marshal.GetLastWin32Error();if(error==38)return true;throw new Win32Exception(error);}int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+4);string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+24),(int)nameLength/2);if(!String.Equals(name,"::$DATA",StringComparison.OrdinalIgnoreCase)&&!String.Equals(name,"::$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase))return false;if(next==0)break;offset+=(int)next;}return true;}finally{Marshal.FreeHGlobal(buffer);}}
    private static string[] Enumerate(SafeFileHandle handle){List<string> result=new List<string>();IntPtr buffer=Marshal.AllocHGlobal(65536);bool restart=true;try{while(true){IO_STATUS_BLOCK io;int status=NtQueryDirectoryFile(handle,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out io,buffer,65536,FileDirectoryInformation,false,IntPtr.Zero,restart);restart=false;if(status==STATUS_NO_MORE_FILES)break;if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+60);string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+64),(int)nameLength/2);if(name!="."&&name!="..")result.Add(name);if(next==0)break;offset+=(int)next;}}return result.ToArray();}finally{Marshal.FreeHGlobal(buffer);}}
    private static OpenResult OpenRelative(SafeFileHandle parent,string name,uint access,uint share,uint disposition,uint options){IntPtr nameBuffer=IntPtr.Zero,unicodePointer=IntPtr.Zero;bool added=false;try{parent.DangerousAddRef(ref added);nameBuffer=Marshal.StringToHGlobalUni(name);UNICODE_STRING unicode=new UNICODE_STRING{Length=(ushort)(name.Length*2),MaximumLength=(ushort)((name.Length+1)*2),Buffer=nameBuffer};unicodePointer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));Marshal.StructureToPtr(unicode,unicodePointer,false);OBJECT_ATTRIBUTES attributes=new OBJECT_ATTRIBUTES{Length=Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)),RootDirectory=parent.DangerousGetHandle(),ObjectName=unicodePointer,Attributes=OBJ_CASE_INSENSITIVE};IO_STATUS_BLOCK io;IntPtr raw;int status=NtCreateFile(out raw,access,ref attributes,out io,IntPtr.Zero,0,share,disposition,options|SYNC_IO|OPEN_REPARSE,IntPtr.Zero,0);if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));return new OpenResult(new SafeFileHandle(raw,true),io.Information.ToUInt64()==2);}finally{if(unicodePointer!=IntPtr.Zero)Marshal.FreeHGlobal(unicodePointer);if(nameBuffer!=IntPtr.Zero)Marshal.FreeHGlobal(nameBuffer);if(added)parent.DangerousRelease();}}
    private static int Rename(SafeFileHandle source,SafeFileHandle parent,string destination){byte[] name=Encoding.Unicode.GetBytes(destination);int rootOffset=IntPtr.Size,lengthOffset=rootOffset+IntPtr.Size,nameOffset=lengthOffset+4,size=nameOffset+name.Length+2;IntPtr buffer=Marshal.AllocHGlobal(size);bool parentAdded=false,sourceAdded=false;try{source.DangerousAddRef(ref sourceAdded);parent.DangerousAddRef(ref parentAdded);for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,0);Marshal.WriteIntPtr(buffer,rootOffset,parent.DangerousGetHandle());Marshal.WriteInt32(buffer,lengthOffset,name.Length);Marshal.Copy(name,0,IntPtr.Add(buffer,nameOffset),name.Length);IO_STATUS_BLOCK io;int status=NtSetInformationFile(source,out io,buffer,(uint)size,FileRenameInformation);return status>=0?0:(int)RtlNtStatusToDosError(status);}finally{if(parentAdded)parent.DangerousRelease();if(sourceAdded)source.DangerousRelease();Marshal.FreeHGlobal(buffer);}}
}
'@
    $script:CcodRuntimeType = [CcodInstallCapabilityMarker].Assembly.GetType('CcodInstallRuntime',$true)
}

function Assert-CcodInstallLeaf([string]$Leaf,[string]$ErrorId='CCOD_INSTALL_LEAF_INVALID') {
    if ([string]::IsNullOrWhiteSpace($Leaf)-or$Leaf.Length-gt 160-or$Leaf-in@('.','..')-or$Leaf-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$'-or$Leaf.EndsWith('.')-or$Leaf-match'^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { Throw-CcodInstallFileError $ErrorId 'Unsafe install leaf' $Leaf }
}
function Invoke-CcodRuntimeStatic([string]$Name,[object[]]$Arguments){$method=$script:CcodRuntimeType.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static');try{return $method.Invoke($null,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}}
function Invoke-CcodRuntimeMethod($Runtime,[string]$Name,[object[]]$Arguments){$method=$Runtime.GetType().GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Instance');try{return $method.Invoke($Runtime,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}}
function New-CcodInstallCapability { New-Object psobject }
function Get-CcodInstallTransaction($Capability,[string]$InvalidId='CCOD_INSTALL_GENERATION_INVALID'){$record=$null;if($null-eq$Capability-or-not$script:CcodScopes.TryGetValue($Capability,[ref]$record)){Throw-CcodInstallFileError $InvalidId 'Invalid install generation capability' $null};$state=$null;if(-not$script:CcodTransactions.TryGetValue($record.Transaction,[ref]$state)){Throw-CcodInstallFileError $InvalidId 'Invalid install transaction capability' $null};if($state.Closed){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' 'Install file transaction is closed' $null};if($state.Retired){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_RETIRED' 'Install generation is retired' $null};[pscustomobject]@{State=$state;Record=$record}}
function Add-CcodInstallScope($Transaction,$Token){$capability=New-CcodInstallCapability;$script:CcodScopes.Add($capability,[pscustomobject]@{Transaction=$Transaction;Token=$Token});$capability}
function Convert-CcodInstallRuntimeError($Action,[string]$DefaultId){try{return&$Action}catch{$exception=$_.Exception;while($null-ne$exception.InnerException-and$exception-is[Management.Automation.RuntimeException]){$exception=$exception.InnerException};$message=[string]$exception.Message;if($exception-is[ObjectDisposedException]){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' $message $null};if($exception-is[ComponentModel.Win32Exception]-and$exception.NativeErrorCode-in@(80,183)){Throw-CcodInstallFileError 'CCOD_INSTALL_LEAF_EXISTS' 'Install object already exists' $null};if($message-match'pointer generation exists'){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_GENERATION_EXISTS' $message $null};if($message-match'alternate stream'){Throw-CcodInstallFileError 'CCOD_INSTALL_ADS_LEAF' $message $null};if($message-match'multi-link'){Throw-CcodInstallFileError 'CCOD_INSTALL_MULTILINK_LEAF' $message $null};if($message-match'reparse'){Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' $message $null};if($message-match'transaction scope'){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_SCOPE' $message $null};if($message-match'generation not owned'){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_NOT_OWNED' $message $null};if($message-match'unknown|unsealed'){Throw-CcodInstallFileError 'CCOD_INSTALL_UNKNOWN_LEAF' $message $null};if($message-match'pin changed|path changed'){Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' $message $null};Throw-CcodInstallFileError $DefaultId $message $null}}
function Test-CcodInstallValue($Value,[int]$Depth=0) {
    if ($Depth -gt 12) { return $false }
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return $Value.Length -le 4096 }
    if ($Value -is [ValueType]) { return $true }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or $key -cnotmatch '^[A-Za-z0-9_.-]{1,96}$' -or -not (Test-CcodInstallValue $Value[$key] ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) { if (-not (Test-CcodInstallValue $item ($Depth + 1))) { return $false } }
        return $true
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -cnotmatch '^[A-Za-z0-9_.-]{1,96}$' -or -not (Test-CcodInstallValue $property.Value ($Depth + 1))) { return $false }
        }
        return $true
    }
    return $false
}
function ConvertTo-CcodInstallJsonBytes($Value){if(-not(Test-CcodInstallValue $Value)){Throw-CcodInstallFileError 'CCOD_INSTALL_JSON_INVALID' 'Invalid install JSON value' $null};return ,([Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 32 -Compress)+"`n"))}
function Assert-CcodInstallRootScope($State,[string]$InstallRoot,[string]$ErrorId){if(-not[IO.Path]::IsPathRooted($InstallRoot)-or-not[String]::Equals([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\'),$State.InstallRoot,[StringComparison]::OrdinalIgnoreCase)){Throw-CcodInstallFileError $ErrorId 'Install root does not match transaction scope' $InstallRoot}}

function Open-CcodInstallGeneration {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId)
    Initialize-CcodInstallRuntime;if(-not[IO.Path]::IsPathRooted($InstallRoot)){Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root must be absolute' $InstallRoot};Assert-CcodInstallLeaf $RuntimeId 'CCOD_INSTALL_RUNTIME_ID_INVALID'
    $arguments=[object[]]@([IO.Path]::GetFullPath($InstallRoot),$RuntimeId,$null)
    try{$token=Invoke-CcodRuntimeStatic Open $arguments}catch [ComponentModel.Win32Exception]{if($_.Exception.NativeErrorCode-in@(32,80,183)){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_EXISTS' 'Install generation already exists' $RuntimeId};throw}
    $runtime=$arguments[2];$transaction=New-CcodInstallCapability;$script:CcodTransactions.Add($transaction,[pscustomobject]@{Runtime=$runtime;InstallRoot=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\');RuntimeId=$RuntimeId;RootToken=$token;Closed=$false;Retired=$false;Disposition=$null});$script:CcodScopes.Add($transaction,[pscustomobject]@{Transaction=$transaction;Token=$token});$transaction
}
function New-CcodInstallGenerationLeaf { param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)][string]$Leaf) Assert-CcodInstallLeaf $Leaf;$scope=Get-CcodInstallTransaction $Generation;$token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime CreateDirectory @($scope.Record.Token,$Leaf)} 'CCOD_INSTALL_LEAF_CREATE_FAILED';Add-CcodInstallScope $scope.Record.Transaction $token }
function Copy-CcodInstallSealedSource { param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)][int64]$ExpectedLength,[Parameter(Mandatory)][string]$ExpectedSha256) Assert-CcodInstallLeaf $Leaf;if(-not[IO.Path]::IsPathRooted($SourcePath)-or$ExpectedLength-lt 0-or$ExpectedSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_INVALID' 'Invalid sealed source contract' $SourcePath};$scope=Get-CcodInstallTransaction $Generation;Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Copy @($scope.Record.Token,$Leaf,[IO.Path]::GetFullPath($SourcePath),$ExpectedLength,$ExpectedSha256)|Out-Null} 'CCOD_INSTALL_SOURCE_MISMATCH';[pscustomobject]@{Length=$ExpectedLength;Sha256=$ExpectedSha256} }
function Write-CcodInstallGenerationManifest { param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)]$Manifest) $scope=Get-CcodInstallTransaction $Generation;if($scope.Record.Token-ne$scope.State.RootToken){Throw-CcodInstallFileError 'CCOD_INSTALL_MANIFEST_SCOPE' 'Manifest must be written at the generation root' $null};$bytes=ConvertTo-CcodInstallJsonBytes $Manifest;$result=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Write @($scope.Record.Token,'manifest.json',$bytes,$true)} 'CCOD_INSTALL_MANIFEST_WRITE_FAILED';[pscustomobject]@{Length=[int64]$result[1];Sha256=[string]$result[2]} }
function Commit-CcodInstallActivePointer { param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][uint64]$ExpectedPreviousGeneration,[Parameter(Mandatory)][string]$NewRuntimeId,[Parameter(Mandatory)]$FileTransaction) Assert-CcodInstallLeaf $NewRuntimeId 'CCOD_INSTALL_RUNTIME_ID_INVALID';$scope=Get-CcodInstallTransaction $FileTransaction 'CCOD_INSTALL_TRANSACTION_INVALID';Assert-CcodInstallRootScope $scope.State $InstallRoot 'CCOD_INSTALL_TRANSACTION_SCOPE';$generation=$ExpectedPreviousGeneration+1;$pointer=[ordered]@{schemaVersion=1;generation=$generation;activeRuntime=$NewRuntimeId;previousGeneration=$ExpectedPreviousGeneration};$bytes=ConvertTo-CcodInstallJsonBytes $pointer;try{Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime CommitPointer @($scope.Record.Token,$ExpectedPreviousGeneration,$NewRuntimeId,$bytes)|Out-Null} 'CCOD_INSTALL_POINTER_COMMIT_FAILED'}catch{if($_.FullyQualifiedErrorId-like'CCOD_INSTALL_LEAF_EXISTS*'){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_GENERATION_EXISTS' 'Pointer generation already exists' $generation};throw};[pscustomobject]@{Generation=[uint64]$generation;RuntimeId=$NewRuntimeId} }
function Retire-CcodInstallGeneration { param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)]$FileTransaction) Assert-CcodInstallLeaf $RuntimeId 'CCOD_INSTALL_RUNTIME_ID_INVALID';$scope=Get-CcodInstallTransaction $FileTransaction 'CCOD_INSTALL_TRANSACTION_INVALID';Assert-CcodInstallRootScope $scope.State $InstallRoot 'CCOD_INSTALL_TRANSACTION_SCOPE';if($RuntimeId-cne$scope.State.RuntimeId-or$scope.Record.Token-ne$scope.State.RootToken){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_NOT_OWNED' 'Generation is not owned by this transaction' $RuntimeId};$retiredLeaf=$RuntimeId+'.'+[guid]::NewGuid().ToString('N');$record=ConvertTo-CcodInstallJsonBytes ([ordered]@{schemaVersion=1;runtimeId=$RuntimeId;retiredName=$retiredLeaf});$token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Retire @($scope.Record.Token,$RuntimeId,$retiredLeaf,$record)} 'CCOD_INSTALL_RETIREMENT_FAILED';$capability=Add-CcodInstallScope $scope.Record.Transaction $token;$scope.State.Retired=$true;[pscustomobject]@{Disposition='Retired';Capability=$capability} }
function Close-CcodInstallFileTransaction { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)][ValidateSet('Ready','Failed')][string]$Disposition) $state=$null;if($null-eq$Transaction-or-not$script:CcodTransactions.TryGetValue($Transaction,[ref]$state)){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Invalid install file transaction capability' $null};if(-not$state.Closed){Invoke-CcodRuntimeMethod $state.Runtime Close @()|Out-Null;$state.Closed=$true;$state.Disposition=$Disposition} }

Initialize-CcodInstallRuntime
Export-ModuleMember -Function Open-CcodInstallGeneration,New-CcodInstallGenerationLeaf,Copy-CcodInstallSealedSource,Write-CcodInstallGenerationManifest,Commit-CcodInstallActivePointer,Retire-CcodInstallGeneration,Close-CcodInstallFileTransaction
