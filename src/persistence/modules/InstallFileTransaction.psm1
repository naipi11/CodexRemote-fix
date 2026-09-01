Set-StrictMode -Version Latest

$script:CcodTransactions = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()
$script:CcodScopes = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()

function Throw-CcodInstallFileError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Initialize-CcodInstallRuntime {
    $marker = 'CcodInstallGenerationCapabilityMarkerV4' -as [type]
    if ($null -eq $marker) {
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

public sealed class CcodInstallGenerationCapabilityMarkerV4
{
    private CcodInstallGenerationCapabilityMarkerV4() { }
    public static int CapabilityAbi { get { return 4; } }
}

internal sealed class CcodInstallGenerationRuntimeV4 : IDisposable
{
    private const uint READ = 0x80000000, WRITE = 0x40000000, DELETE = 0x00010000, SYNC = 0x00100000;
    private const uint READ_ATTRIBUTES = 0x80, WRITE_ATTRIBUTES = 0x100, LIST_DIRECTORY = 0x1, ADD_FILE = 0x2, ADD_SUBDIRECTORY = 0x4;
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
        internal readonly uint Volume; internal readonly ulong Index; internal bool Closed, Sealed, Published, Manifest; internal long SealedLength; internal string SealedSha;
        internal Pin(Pin parent,string leaf,string path,bool directory,bool owned,SafeFileHandle handle,FileStream stream,FILE_INFO info)
        { Parent=parent;Leaf=leaf;Path=path;Directory=directory;Owned=owned;Handle=handle;Stream=stream;Volume=info.VolumeSerialNumber;Index=((ulong)info.FileIndexHigh<<32)|info.FileIndexLow; }
        internal SafeFileHandle Native { get { return Stream != null ? Stream.SafeFileHandle : Handle; } }
        public void Dispose() { if(Closed)return;if(Stream!=null)Stream.Dispose();else if(Handle!=null)Handle.Dispose();Closed=true; }
    }

    private sealed class ReferenceComparer : IEqualityComparer<object>
    { internal static readonly ReferenceComparer Instance=new ReferenceComparer();public new bool Equals(object x,object y){return Object.ReferenceEquals(x,y);}public int GetHashCode(object x){return RuntimeHelpers.GetHashCode(x);} }
    private sealed class OpenResult { internal SafeFileHandle Handle; internal bool Created; internal OpenResult(SafeFileHandle handle,bool created){Handle=handle;Created=created;} }

    private readonly string installRoot; private readonly Pin root, runtimeParent;
    private readonly Dictionary<object,Pin> pins = new Dictionary<object,Pin>(ReferenceComparer.Instance);
    private readonly Dictionary<string,Pin> names = new Dictionary<string,Pin>(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<object> retainedRoots = new HashSet<object>(ReferenceComparer.Instance);
    private readonly HashSet<object> retainedScopes = new HashSet<object>(ReferenceComparer.Instance);
    private readonly HashSet<object> productFolders = new HashSet<object>(ReferenceComparer.Instance);
    private readonly List<FileStream> externalStreams = new List<FileStream>();
    private bool disposed; private string cleanupError;

    private readonly bool stateOnly,productOnly;
    private CcodInstallGenerationRuntimeV4(string installRoot,Pin root,Pin runtimeParent,bool stateOnly,bool productOnly)
    { this.installRoot=installRoot;this.root=root;this.runtimeParent=runtimeParent;this.stateOnly=stateOnly;this.productOnly=productOnly;AddPin(root);if(runtimeParent!=null)AddPin(runtimeParent); }

    internal static object Open(string path,string runtimeId,out CcodInstallGenerationRuntimeV4 runtime)
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
            OpenResult generationResult=OpenRelative(runtimePin.Native,runtimeId,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,SHARE_READ|SHARE_WRITE,CREATE,DIRECTORY|BACKUP_INTENT);
            try
            {
                Pin generation=ValidateDirectoryPin(runtimePin,runtimeId,Path.Combine(runtimePin.Path,runtimeId),true,generationResult.Handle);generationResult.Handle=null;
                runtime=new CcodInstallGenerationRuntimeV4(full,rootPin,runtimePin,false,false);rootPin=null;runtimePin=null;runtime.AddPin(generation);return generation.Token;
            }
            finally { if(generationResult.Handle!=null)generationResult.Handle.Dispose(); }
        }
        catch { if(runtimePin!=null)runtimePin.Dispose();if(rootPin!=null)rootPin.Dispose();if(rootHandle!=null)rootHandle.Dispose();throw; }
    }

    internal static object OpenState(string path,out CcodInstallGenerationRuntimeV4 runtime)
    {
        runtime=null;string full=Path.GetFullPath(path).TrimEnd('\\');SafeFileHandle rootHandle=OpenAbsoluteDirectory(full,true);Pin rootPin=null;
        try{rootPin=ValidateDirectoryPin(null,"",full,false,rootHandle);rootHandle=null;runtime=new CcodInstallGenerationRuntimeV4(full,rootPin,null,true,false);rootPin=null;return runtime.root.Token;}
        catch{if(rootPin!=null)rootPin.Dispose();if(rootHandle!=null)rootHandle.Dispose();throw;}
    }

    internal static object OpenProduct(string path,out CcodInstallGenerationRuntimeV4 runtime)
    {
        runtime=null;string full=Path.GetFullPath(path).TrimEnd('\\');SafeFileHandle rootHandle=OpenAbsoluteDirectory(full,false);Pin rootPin=null,runtimePin=null;
        try{rootPin=ValidateDirectoryPin(null,"",full,false,rootHandle);rootHandle=null;OpenResult result=OpenRelative(rootPin.Native,"runtime",LIST_DIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);try{runtimePin=ValidateDirectoryPin(rootPin,"runtime",Path.Combine(full,"runtime"),false,result.Handle);result.Handle=null;}finally{if(result.Handle!=null)result.Handle.Dispose();};runtime=new CcodInstallGenerationRuntimeV4(full,rootPin,runtimePin,false,true);rootPin=null;runtimePin=null;return runtime.root.Token;}catch{if(runtimePin!=null)runtimePin.Dispose();if(rootPin!=null)rootPin.Dispose();if(rootHandle!=null)rootHandle.Dispose();throw;}
    }

    private bool IsStateScope(Pin pin){for(Pin cursor=pin;cursor!=null;cursor=cursor.Parent)if(Object.ReferenceEquals(cursor.Parent,root)&&String.Equals(cursor.Leaf,"state",StringComparison.Ordinal))return true;return false;}
    private void RequireStateDirectory(Pin parent,string leaf){if(productOnly)throw new InvalidOperationException("product-only scope");if(!stateOnly)return;if(Object.ReferenceEquals(parent,root)){if(!String.Equals(leaf,"state",StringComparison.Ordinal))throw new InvalidOperationException("state-only scope");return;}if(!IsStateScope(parent))throw new InvalidOperationException("state-only scope");}

    [MethodImpl(MethodImplOptions.Synchronized)] internal object CreateDirectory(object parentToken,string leaf)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);RequireStateDirectory(parent,leaf);OpenResult result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,SHARE_READ|SHARE_WRITE,CREATE,DIRECTORY|BACKUP_INTENT);
        try { Pin pin=ValidateDirectoryPin(parent,leaf,Path.Combine(parent.Path,leaf),true,result.Handle);result.Handle=null;AddPin(pin);return pin.Token; }
        finally { if(result.Handle!=null)result.Handle.Dispose(); }
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object OpenDirectory(object parentToken,string leaf,bool createIfMissing)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);RequireStateDirectory(parent,leaf);Pin known;if(names.TryGetValue(Key(parent,leaf),out known)){ValidateCurrent(known);if(retainedScopes.Contains(parentToken)||retainedRoots.Contains(known.Token))MarkRetainedTree(known);return known.Token;}OpenResult result;
        if(createIfMissing){try{result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,CREATE,DIRECTORY|BACKUP_INTENT);}catch(Win32Exception exception){if(exception.NativeErrorCode!=80&&exception.NativeErrorCode!=183)throw;result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);}}
        else result=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);
        try{Pin pin=ValidateDirectoryPin(parent,leaf,Path.Combine(parent.Path,leaf),result.Created,result.Handle);result.Handle=null;AddPin(pin);if(retainedScopes.Contains(parentToken))retainedScopes.Add(pin.Token);return pin.Token;}finally{if(result.Handle!=null)result.Handle.Dispose();}
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object GetInstallRoot(){if(disposed)throw new ObjectDisposedException("transaction");ValidateCurrent(root);return root.Token;}
    [MethodImpl(MethodImplOptions.Synchronized)] internal bool IsRetained(object token){if(disposed)throw new ObjectDisposedException("transaction");return token!=null&&retainedScopes.Contains(token);}

    [MethodImpl(MethodImplOptions.Synchronized)] internal object OpenRetained(string runtimeId,string expectedManifestSha)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");if(disposed)throw new ObjectDisposedException("transaction");Pin existing;if(names.TryGetValue(Key(runtimeParent,runtimeId),out existing)){if(!retainedRoots.Contains(existing.Token))throw new InvalidDataException("retained generation already scoped");ValidateRetainedTree(existing);return new object[]{existing.Token,ValidateRetainedManifest(existing,expectedManifestSha)};}OpenResult result=OpenRelative(runtimeParent.Native,runtimeId,LIST_DIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);List<Pin> added=new List<Pin>();
        try
        {
            Pin candidate=ValidateDirectoryPin(runtimeParent,runtimeId,Path.Combine(runtimeParent.Path,runtimeId),false,result.Handle);result.Handle=null;Pin generation;if(names.TryGetValue(Key(runtimeParent,runtimeId),out generation)){candidate.Dispose();}else{generation=candidate;AddPin(generation);added.Add(generation);}OpenRetainedTree(generation,added);
            string manifestText=ValidateRetainedManifest(generation,expectedManifestSha);ValidateRetainedTree(generation);retainedRoots.Add(generation.Token);MarkRetainedTree(generation);return new object[]{generation.Token,manifestText};
        }
        catch(Exception exception){for(int i=added.Count-1;i>=0;i--){Pin pin=added[i];retainedScopes.Remove(pin.Token);if(pin.Parent!=null)names.Remove(Key(pin.Parent,pin.Leaf));pins.Remove(pin.Token);try{pin.Dispose();}catch{}}throw new InvalidDataException("retained open failed: "+exception.Message,exception);}
        finally{if(result.Handle!=null)result.Handle.Dispose();}
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object Copy(object parentToken,string leaf,string source,long expectedLength,string expectedSha)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");if(productOnly)throw new InvalidOperationException("product-only scope");Pin parent=Require(parentToken,true);ValidateCurrent(parent);string full=Path.GetFullPath(source);
        SafeFileHandle sourceHandle=CreateFileW(full,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,IntPtr.Zero,OPEN_EXISTING,FLAG_REPARSE,IntPtr.Zero);
        if(sourceHandle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());FileStream sourceStream=null;
        try
        {
            FILE_INFO sourceInfo=Info(sourceHandle);ValidatePlain(sourceInfo,sourceHandle);if(!SamePath(FinalPath(sourceHandle),full))throw new InvalidDataException("source path changed");
            sourceStream=new FileStream(sourceHandle,FileAccess.Read,65536,false);sourceHandle=null;
            externalStreams.Add(sourceStream);FileStream ownedSource=sourceStream;sourceStream=null;
            if(ownedSource.Length!=expectedLength||Sha(ownedSource)!=expectedSha)throw new InvalidDataException("source mismatch");ownedSource.Position=0;
            Pin destination=CreateTemporaryFile(parent);ownedSource.CopyTo(destination.Stream);destination.Stream.Flush(true);
            if(destination.Stream.Length!=expectedLength||Sha(destination.Stream)!=expectedSha)throw new InvalidDataException("destination mismatch");SealAndPublish(destination,leaf,expectedLength,expectedSha,false);return destination.Token;
        }
        finally { if(sourceStream!=null)sourceStream.Dispose();if(sourceHandle!=null)sourceHandle.Dispose(); }
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object Write(object parentToken,string leaf,byte[] bytes,bool manifest)
    {
        if(productOnly)throw new InvalidOperationException("product-only scope");Pin parent=Require(parentToken,true);ValidateCurrent(parent);if(stateOnly&&(manifest||!IsStateScope(parent)))throw new InvalidOperationException("state-only scope");Pin pin=CreateTemporaryFile(parent);pin.Stream.Write(bytes,0,bytes.Length);pin.Stream.Flush(true);string sha=Sha(pin.Stream);if(pin.Stream.Length!=bytes.LongLength)throw new InvalidDataException("destination mismatch");SealAndPublish(pin,leaf,bytes.LongLength,sha,manifest);return pin.Token;
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object CommitPointer(object generationToken,ulong previousGeneration,string runtimeId,byte[] bytes)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");if(productOnly)throw new InvalidOperationException("product-only scope");Pin generation=Require(generationToken,true);ValidateCurrent(generation);if(!Object.ReferenceEquals(generation.Parent,runtimeParent)||!String.Equals(generation.Leaf,runtimeId,StringComparison.Ordinal))throw new InvalidDataException("transaction scope");
        if(retainedRoots.Contains(generationToken))ValidateRetainedTree(generation);else{Pin manifest=null;if(!names.TryGetValue(Key(generation,"manifest.json"),out manifest)||!manifest.Manifest||!manifest.Sealed)throw new InvalidDataException("manifest missing");EnsurePublishedPin(manifest);ValidateOwnedTree(generation);}
        if(previousGeneration==UInt64.MaxValue)throw new OverflowException("pointer generation overflow");Pin state=OpenOrCreateDirectory(root,"state"),pointer=OpenOrCreateDirectory(state,"active-generation");if(CurrentPointerGeneration(pointer)!=previousGeneration)throw new InvalidOperationException("pointer generation exists");string leaf=(previousGeneration+1).ToString("D20")+".json";return Write(pointer.Token,leaf,bytes,false);
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object Retire(object generationToken,string runtimeId,string recordLeaf,byte[] record)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");if(productOnly)throw new InvalidOperationException("product-only scope");Pin generation=Require(generationToken,true);ValidateCurrent(generation);if(!Object.ReferenceEquals(generation.Parent,runtimeParent)||!String.Equals(generation.Leaf,runtimeId,StringComparison.Ordinal)||!generation.Owned)throw new InvalidDataException("generation not owned");
        ValidateOwnedTree(generation);Pin state=OpenOrCreateDirectory(root,"state"),retirements=OpenOrCreateDirectory(state,"retired-generations");Write(retirements.Token,recordLeaf,record,false);return generation.Token;
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object OpenProductFolder(string kind,string path)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");if(disposed)throw new ObjectDisposedException("transaction");
        string full=Path.GetFullPath(path).TrimEnd('\\');SafeFileHandle handle=OpenAbsoluteDirectory(full,true);Pin basePin=null;
        try
        {
            basePin=ValidateDirectoryPin(null,"",full,false,handle);handle=null;AddPin(basePin);
            Pin selected=basePin;
            if(String.Equals(kind,"StartMenu",StringComparison.Ordinal))selected=OpenOrCreateDirectory(basePin,"CodexRemote-fix");
            else if(!String.Equals(kind,"Desktop",StringComparison.Ordinal))throw new InvalidDataException("unknown product folder");
            productFolders.Add(selected.Token);return selected.Token;
        }
        catch{if(handle!=null)handle.Dispose();throw;}
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object OpenRetainedFile(object generationToken,string relative)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");if(relative!="registration/StartMenu.CodexRemote-fix.lnk"&&relative!="registration/Desktop.CodexRemote-fix.lnk")throw new InvalidDataException("product shortcut source");Pin cursor=Require(generationToken,true);ValidateCurrent(cursor);string[] segments=relative.Split('/');for(int i=0;i<segments.Length;i++){Pin next;if(!names.TryGetValue(Key(cursor,segments[i]),out next))throw new InvalidDataException("product shortcut source");if(i<segments.Length-1){if(!next.Directory)throw new InvalidDataException("product shortcut source");ValidateCurrent(next);cursor=next;}else{if(next.Directory||!next.Sealed||!next.Published)throw new InvalidDataException("product shortcut source");ValidateCurrent(next);return new object[]{next.Token,next.SealedLength,next.SealedSha};}}throw new InvalidDataException("product shortcut source");
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal object CopyProductShortcut(object folderToken,string kind,object sourceToken,string leaf)
    {
        if(stateOnly)throw new InvalidOperationException("state-only scope");Pin parent=Require(folderToken,true);ValidateCurrent(parent);Pin source=Require(sourceToken,false);ValidateCurrent(source);
        if(!productFolders.Contains(folderToken)||!String.Equals(leaf,"CodexRemote-fix.lnk",StringComparison.Ordinal)||
           (!String.Equals(kind,"StartMenu",StringComparison.Ordinal)&&!String.Equals(kind,"Desktop",StringComparison.Ordinal)))throw new InvalidDataException("product shortcut scope");
        long expectedLength=source.SealedLength;string expectedSha=source.SealedSha;if(source.Stream.Length!=expectedLength||Sha(source.Stream)!=expectedSha)throw new InvalidDataException("source mismatch");source.Stream.Position=0;
            Pin destination=CreateTemporaryFile(parent);source.Stream.CopyTo(destination.Stream);destination.Stream.Flush(true);
            if(destination.Stream.Length!=expectedLength||Sha(destination.Stream)!=expectedSha)throw new InvalidDataException("destination mismatch");
            SealAndReplaceProduct(destination,leaf,expectedLength,expectedSha);EnsurePublishedPin(destination);return destination.Token;
    }

    [MethodImpl(MethodImplOptions.Synchronized)] internal void Close()
    {
        disposed=true;Exception first=null;List<FileStream> failedStreams=new List<FileStream>();foreach(FileStream stream in new List<FileStream>(externalStreams)){try{stream.Dispose();}catch(Exception exception){failedStreams.Add(stream);if(first==null)first=exception;}}externalStreams.Clear();externalStreams.AddRange(failedStreams);
        List<Pin> all=new List<Pin>(pins.Values);for(int i=all.Count-1;i>=0;i--){Pin pin=all[i];try{pin.Dispose();}catch(Exception exception){if(first==null)first=exception;}if(pin.Closed)pins.Remove(pin.Token);}if(pins.Count==0)names.Clear();
        if(first!=null){cleanupError="registered resource cleanup failed";throw new InvalidOperationException(cleanupError);}cleanupError=null;
    }
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
        ValidateCurrent(directory);foreach(string leaf in Enumerate(directory.Native)){Pin child;if(!names.TryGetValue(Key(directory,leaf),out child)||!child.Owned)throw new InvalidDataException("unknown leaf");if(child.Directory){ValidateCurrent(child);ValidateOwnedTree(child);}else{if(!child.Sealed||!child.Published)throw new InvalidDataException("unsealed leaf");EnsurePublishedPin(child);}}
    }
    private void OpenRetainedTree(Pin directory,List<Pin> added)
    {
        foreach(string leaf in Enumerate(directory.Native))
        {
            OpenResult probe=OpenRelative(directory.Native,leaf,READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,BACKUP_INTENT);try{FILE_INFO info=Info(probe.Handle);if((info.FileAttributes&ATTR_REPARSE)!=0)throw new InvalidDataException("reparse leaf");string path=Path.Combine(directory.Path,leaf);if(IsDirectory(info)){probe.Handle.Dispose();probe.Handle=null;OpenResult childDirectory=OpenRelative(directory.Native,leaf,LIST_DIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);try{FILE_INFO childInfo=Info(childDirectory.Handle);if(!IsDirectory(childInfo)||(childInfo.FileAttributes&ATTR_REPARSE)!=0||!OnlyDefaultStream(childDirectory.Handle)||!SamePath(FinalPath(childDirectory.Handle),path))throw new InvalidDataException("directory invalid");Pin child=new Pin(directory,leaf,path,true,false,childDirectory.Handle,null,childInfo);childDirectory.Handle=null;AddPin(child);added.Add(child);retainedScopes.Add(child.Token);OpenRetainedTree(child,added);}finally{if(childDirectory.Handle!=null)childDirectory.Handle.Dispose();}}else{probe.Handle.Dispose();probe.Handle=null;OpenResult file=OpenRelative(directory.Native,leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);FileStream stream=null;try{stream=new FileStream(file.Handle,FileAccess.Read,65536,false);file.Handle=null;FILE_INFO fileInfo=Info(stream.SafeFileHandle);ValidatePlain(fileInfo,stream.SafeFileHandle);if(!SamePath(FinalPath(stream.SafeFileHandle),path))throw new InvalidDataException("pin changed");Pin child=new Pin(directory,leaf,path,false,false,null,stream,fileInfo);child.SealedLength=stream.Length;child.SealedSha=Sha(stream);child.Sealed=true;child.Published=true;AddPin(child);added.Add(child);retainedScopes.Add(child.Token);stream=null;}finally{if(stream!=null)stream.Dispose();if(file.Handle!=null)file.Handle.Dispose();}}}finally{if(probe.Handle!=null)probe.Handle.Dispose();}}
    }
    private void ValidateRetainedTree(Pin directory){ValidateCurrent(directory);foreach(string leaf in Enumerate(directory.Native)){Pin child;if(!names.TryGetValue(Key(directory,leaf),out child))throw new InvalidDataException("unknown retained leaf");if(child.Directory)ValidateRetainedTree(child);else{ValidateCurrent(child);if(child.Stream.Length!=child.SealedLength||Sha(child.Stream)!=child.SealedSha)throw new InvalidDataException("seal mismatch");}}}
    private string ValidateRetainedManifest(Pin generation,string expectedManifestSha){Pin manifest;if(!names.TryGetValue(Key(generation,"manifest.json"),out manifest)||manifest.Directory)throw new InvalidDataException("retained manifest missing");if(manifest.SealedSha!=expectedManifestSha)throw new InvalidDataException("retained manifest mismatch");return ReadText(manifest.Stream);}
    private void MarkRetainedTree(Pin directory){retainedScopes.Add(directory.Token);foreach(Pin pin in pins.Values)if(!pin.Closed&&pin.Path.StartsWith(directory.Path.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))retainedScopes.Add(pin.Token);}
    private static string ReadText(FileStream stream){if(stream.Length>4194304)throw new InvalidDataException("retained manifest too large");long position=stream.Position;try{stream.Position=0;byte[] bytes=new byte[stream.Length];int offset=0;while(offset<bytes.Length){int read=stream.Read(bytes,offset,bytes.Length-offset);if(read==0)break;offset+=read;}if(offset!=bytes.Length)throw new EndOfStreamException();return new UTF8Encoding(false,true).GetString(bytes);}finally{stream.Position=position;}}
    private Pin CreateTemporaryFile(Pin parent)
    {
        string temporary=".ccod."+Guid.NewGuid().ToString("N")+".tmp";OpenResult result=OpenRelative(parent.Native,temporary,READ|WRITE|DELETE|SYNC,SHARE_READ,CREATE,NON_DIRECTORY|WRITE_THROUGH);FileStream stream=null;try{stream=new FileStream(result.Handle,FileAccess.ReadWrite,65536,false);result.Handle=null;FILE_INFO info=Info(stream.SafeFileHandle);ValidatePlain(info,stream.SafeFileHandle);Pin pin=new Pin(parent,temporary,Path.Combine(parent.Path,temporary),false,true,null,stream,info);AddPin(pin);stream=null;return pin;}finally{if(stream!=null)stream.Dispose();if(result.Handle!=null)result.Handle.Dispose();}
    }
    private static ulong CurrentPointerGeneration(Pin pointer)
    {
        ulong maximum=0;foreach(string leaf in Enumerate(pointer.Native)){if(leaf.StartsWith(".ccod.",StringComparison.OrdinalIgnoreCase)&&leaf.EndsWith(".tmp",StringComparison.OrdinalIgnoreCase))continue;if(leaf.Length!=25||!leaf.EndsWith(".json",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("unknown pointer leaf");ulong value;if(!UInt64.TryParse(leaf.Substring(0,20),out value)||value==0)throw new InvalidDataException("unknown pointer leaf");if(value>maximum)maximum=value;}return maximum;
    }
    private Pin Require(object token,bool directory){if(disposed)throw new ObjectDisposedException("transaction");Pin pin;if(token==null||!pins.TryGetValue(token,out pin)||pin.Closed||pin.Directory!=directory)throw new InvalidDataException("invalid capability");return pin;}
    private void AddPin(Pin pin){if(pins.ContainsKey(pin.Token))throw new InvalidDataException("duplicate pin token");if(pin.Parent!=null&&names.ContainsKey(Key(pin.Parent,pin.Leaf)))throw new InvalidDataException("duplicate pin key "+pin.Parent.Path+" -> "+pin.Leaf);pins.Add(pin.Token,pin);if(pin.Parent!=null)names.Add(Key(pin.Parent,pin.Leaf),pin);}
    private static string Key(Pin parent,string leaf){return parent.Index.ToString("x16")+"|"+leaf.ToLowerInvariant();}
    private static Pin ValidateDirectoryPin(Pin parent,string leaf,string path,bool owned,SafeFileHandle handle){FILE_INFO info=Info(handle);if(!IsDirectory(info)||(info.FileAttributes&ATTR_REPARSE)!=0||!OnlyDefaultStream(handle)||!SamePath(FinalPath(handle),path))throw new InvalidDataException("directory invalid");return new Pin(parent,leaf,path,true,owned,handle,null,info);}
    private void SealAndPublish(Pin pin,string finalLeaf,long expectedLength,string expectedSha,bool manifest)
    {
        string temporaryKey=Key(pin.Parent,pin.Leaf),finalKey=Key(pin.Parent,finalLeaf),finalPath=Path.Combine(pin.Parent.Path,finalLeaf);bool finalAlias=false,committed=false;OpenResult renameHandle=null,strict=null;FileStream strictStream=null;string stage="strict";try
        {
            pin.Stream.Dispose();pin.Stream=null;strict=OpenRelative(pin.Parent.Native,pin.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);strictStream=new FileStream(strict.Handle,FileAccess.Read,65536,false);strict.Handle=null;
            FILE_INFO strictInfo=Info(strictStream.SafeFileHandle);ValidatePlain(strictInfo,strictStream.SafeFileHandle);if(strictInfo.VolumeSerialNumber!=pin.Volume||(((ulong)strictInfo.FileIndexHigh<<32)|strictInfo.FileIndexLow)!=pin.Index||!SamePath(FinalPath(strictStream.SafeFileHandle),pin.Path)||strictStream.Length!=expectedLength||Sha(strictStream)!=expectedSha)throw new InvalidDataException("seal mismatch");
            strictStream.Dispose();strictStream=null;stage="rename-open";renameHandle=OpenRelative(pin.Parent.Native,pin.Leaf,READ|DELETE|READ_ATTRIBUTES|WRITE_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);FILE_INFO renameInfo=Info(renameHandle.Handle);ValidatePlain(renameInfo,renameHandle.Handle);if(renameInfo.VolumeSerialNumber!=pin.Volume||(((ulong)renameInfo.FileIndexHigh<<32)|renameInfo.FileIndexLow)!=pin.Index||!SamePath(FinalPath(renameHandle.Handle),pin.Path))throw new InvalidDataException("pin changed");int attributeError=SetReadOnly(renameHandle.Handle);if(attributeError!=0)throw new Win32Exception(attributeError);pin.SealedLength=expectedLength;pin.SealedSha=expectedSha;pin.Manifest=manifest;pin.Sealed=true;
            if(names.ContainsKey(finalKey))throw new Win32Exception(183);names.Add(finalKey,pin);finalAlias=true;stage="rename";int error=Rename(renameHandle.Handle,pin.Parent.Native,finalLeaf);if(error!=0)throw new Win32Exception(error);committed=true;
            names.Remove(temporaryKey);pin.Leaf=finalLeaf;pin.Path=finalPath;pin.Published=true;
        }
        catch(Exception exception){if(finalAlias&&!committed)names.Remove(finalKey);Win32Exception win32=exception as Win32Exception;if((stage=="rename"||stage=="rename-open")&&win32!=null&&(win32.NativeErrorCode==80||win32.NativeErrorCode==183))throw;throw new InvalidDataException("seal mismatch at "+stage+(win32==null?"":" win32="+win32.NativeErrorCode),exception);}
        finally{if(strictStream!=null)strictStream.Dispose();if(strict!=null&&strict.Handle!=null)strict.Handle.Dispose();if(renameHandle!=null&&renameHandle.Handle!=null)renameHandle.Handle.Dispose();}
    }
    private void SealAndReplaceProduct(Pin pin,string finalLeaf,long expectedLength,string expectedSha)
    {
        string temporaryKey=Key(pin.Parent,pin.Leaf),finalKey=Key(pin.Parent,finalLeaf),finalPath=Path.Combine(pin.Parent.Path,finalLeaf);OpenResult renameHandle=null,strict=null;FileStream strictStream=null;
        try
        {
            pin.Stream.Dispose();pin.Stream=null;strict=OpenRelative(pin.Parent.Native,pin.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);strictStream=new FileStream(strict.Handle,FileAccess.Read,65536,false);strict.Handle=null;
            FILE_INFO strictInfo=Info(strictStream.SafeFileHandle);ValidatePlain(strictInfo,strictStream.SafeFileHandle);if(strictInfo.VolumeSerialNumber!=pin.Volume||(((ulong)strictInfo.FileIndexHigh<<32)|strictInfo.FileIndexLow)!=pin.Index||!SamePath(FinalPath(strictStream.SafeFileHandle),pin.Path)||strictStream.Length!=expectedLength||Sha(strictStream)!=expectedSha)throw new InvalidDataException("seal mismatch");
            strictStream.Dispose();strictStream=null;renameHandle=OpenRelative(pin.Parent.Native,pin.Leaf,READ|DELETE|READ_ATTRIBUTES|WRITE_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);FILE_INFO renameInfo=Info(renameHandle.Handle);ValidatePlain(renameInfo,renameHandle.Handle);if(renameInfo.VolumeSerialNumber!=pin.Volume||(((ulong)renameInfo.FileIndexHigh<<32)|renameInfo.FileIndexLow)!=pin.Index||!SamePath(FinalPath(renameHandle.Handle),pin.Path))throw new InvalidDataException("pin changed");
            pin.SealedLength=expectedLength;pin.SealedSha=expectedSha;pin.Sealed=true;
            Pin old;if(names.TryGetValue(finalKey,out old)&&!Object.ReferenceEquals(old,pin))throw new InvalidDataException("product shortcut already scoped");
            int error=RenameReplacing(renameHandle.Handle,pin.Parent.Native,finalLeaf);if(error!=0)throw new Win32Exception(error);names.Remove(temporaryKey);names[finalKey]=pin;pin.Leaf=finalLeaf;pin.Path=finalPath;pin.Published=true;
        }
        catch(Exception exception){throw new InvalidDataException("seal mismatch at product shortcut",exception);}
        finally{if(strictStream!=null)strictStream.Dispose();if(strict!=null&&strict.Handle!=null)strict.Handle.Dispose();if(renameHandle!=null&&renameHandle.Handle!=null)renameHandle.Handle.Dispose();}
    }
    private void EnsurePublishedPin(Pin pin){if(pin.Stream!=null){ValidateCurrent(pin);return;}OpenResult result=OpenRelative(pin.Parent.Native,pin.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,OPEN,NON_DIRECTORY);FileStream stream=null;try{stream=new FileStream(result.Handle,FileAccess.Read,65536,false);result.Handle=null;FILE_INFO info=Info(stream.SafeFileHandle);ValidatePlain(info,stream.SafeFileHandle);if(info.VolumeSerialNumber!=pin.Volume||(((ulong)info.FileIndexHigh<<32)|info.FileIndexLow)!=pin.Index||!SamePath(FinalPath(stream.SafeFileHandle),pin.Path)||stream.Length!=pin.SealedLength||Sha(stream)!=pin.SealedSha)throw new InvalidDataException("seal mismatch");pin.Stream=stream;stream=null;}finally{if(stream!=null)stream.Dispose();if(result.Handle!=null)result.Handle.Dispose();}}
    private static int SetReadOnly(SafeFileHandle handle){IntPtr buffer=Marshal.AllocHGlobal(40);try{for(int i=0;i<40;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteInt32(buffer,32,1);IO_STATUS_BLOCK io;int status=NtSetInformationFile(handle,out io,buffer,40,4);return status>=0?0:(int)RtlNtStatusToDosError(status);}finally{Marshal.FreeHGlobal(buffer);}}
    private static SafeFileHandle OpenAbsoluteDirectory(string path,bool allowWrite){uint access=LIST_DIRECTORY|READ_ATTRIBUTES|SYNC;if(allowWrite)access|=ADD_FILE|ADD_SUBDIRECTORY;SafeFileHandle handle=CreateFileW(path,access,SHARE_READ|SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,FLAG_BACKUP|FLAG_REPARSE,IntPtr.Zero);if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());return handle;}
    private static void ValidateCurrent(Pin pin){FILE_INFO info=Info(pin.Native);if(info.VolumeSerialNumber!=pin.Volume||(((ulong)info.FileIndexHigh<<32)|info.FileIndexLow)!=pin.Index||IsDirectory(info)!=pin.Directory||(info.FileAttributes&ATTR_REPARSE)!=0||!SamePath(FinalPath(pin.Native),pin.Path))throw new InvalidDataException("pin changed");if(!OnlyDefaultStream(pin.Native))throw new InvalidDataException("alternate stream");if(!pin.Directory&&info.NumberOfLinks!=1)throw new InvalidDataException("multi-link");}
    private static void ValidatePlain(FILE_INFO info,SafeFileHandle handle){if(IsDirectory(info))throw new InvalidDataException("file type");if((info.FileAttributes&ATTR_REPARSE)!=0)throw new InvalidDataException("reparse leaf");if(info.NumberOfLinks!=1)throw new InvalidDataException("multi-link");if(!OnlyDefaultStream(handle))throw new InvalidDataException("alternate stream");}
    private static bool IsDirectory(FILE_INFO info){return(info.FileAttributes&ATTR_DIRECTORY)!=0;}
    private static FILE_INFO Info(SafeFileHandle handle){FILE_INFO info;if(handle==null||handle.IsClosed||!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());return info;}
    private static string Sha(FileStream stream){long position=stream.Position;using(SHA256 hash=SHA256.Create()){stream.Position=0;string value=BitConverter.ToString(hash.ComputeHash(stream)).Replace("-","").ToLowerInvariant();stream.Position=position;return value;}}
    private static string FinalPath(SafeFileHandle handle){StringBuilder buffer=new StringBuilder(512);uint length=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,0);if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());if(length>=buffer.Capacity){buffer.Capacity=(int)length+1;length=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,0);if(length==0||length>=buffer.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());}string path=buffer.ToString();if(path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return@"\\"+path.Substring(8);if(path.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return path.Substring(4);return path;}
    private static bool SamePath(string first,string second){return String.Equals(Path.GetFullPath(first).TrimEnd('\\'),Path.GetFullPath(second).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);}
    private static bool OnlyDefaultStream(SafeFileHandle handle){IntPtr buffer=Marshal.AllocHGlobal(65536);try{if(!GetFileInformationByHandleEx(handle,FileStreamInfo,buffer,65536)){int error=Marshal.GetLastWin32Error();if(error==38)return true;throw new Win32Exception(error);}int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+4);string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+24),(int)nameLength/2);if(!String.Equals(name,"::$DATA",StringComparison.OrdinalIgnoreCase)&&!String.Equals(name,"::$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase))return false;if(next==0)break;offset+=(int)next;}return true;}finally{Marshal.FreeHGlobal(buffer);}}
    private static string[] Enumerate(SafeFileHandle handle){List<string> result=new List<string>();HashSet<string> seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);IntPtr buffer=Marshal.AllocHGlobal(65536);bool restart=true;try{while(true){IO_STATUS_BLOCK io;int status=NtQueryDirectoryFile(handle,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out io,buffer,65536,FileDirectoryInformation,false,IntPtr.Zero,restart);restart=false;if(status==STATUS_NO_MORE_FILES)break;if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));int offset=0;while(true){uint next=(uint)Marshal.ReadInt32(buffer,offset),nameLength=(uint)Marshal.ReadInt32(buffer,offset+60);string name=Marshal.PtrToStringUni(IntPtr.Add(buffer,offset+64),(int)nameLength/2);if(name!="."&&name!=".."&&seen.Add(name))result.Add(name);if(next==0)break;offset+=(int)next;}}return result.ToArray();}finally{Marshal.FreeHGlobal(buffer);}}
    private static OpenResult OpenRelative(SafeFileHandle parent,string name,uint access,uint share,uint disposition,uint options){IntPtr nameBuffer=IntPtr.Zero,unicodePointer=IntPtr.Zero;bool added=false;try{parent.DangerousAddRef(ref added);nameBuffer=Marshal.StringToHGlobalUni(name);UNICODE_STRING unicode=new UNICODE_STRING{Length=(ushort)(name.Length*2),MaximumLength=(ushort)((name.Length+1)*2),Buffer=nameBuffer};unicodePointer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));Marshal.StructureToPtr(unicode,unicodePointer,false);OBJECT_ATTRIBUTES attributes=new OBJECT_ATTRIBUTES{Length=Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)),RootDirectory=parent.DangerousGetHandle(),ObjectName=unicodePointer,Attributes=OBJ_CASE_INSENSITIVE};IO_STATUS_BLOCK io;IntPtr raw;int status=NtCreateFile(out raw,access,ref attributes,out io,IntPtr.Zero,0,share,disposition,options|SYNC_IO|OPEN_REPARSE,IntPtr.Zero,0);if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));return new OpenResult(new SafeFileHandle(raw,true),io.Information.ToUInt64()==2);}finally{if(unicodePointer!=IntPtr.Zero)Marshal.FreeHGlobal(unicodePointer);if(nameBuffer!=IntPtr.Zero)Marshal.FreeHGlobal(nameBuffer);if(added)parent.DangerousRelease();}}
    private static int Rename(SafeFileHandle source,SafeFileHandle parent,string destination){byte[] name=Encoding.Unicode.GetBytes(destination);int rootOffset=IntPtr.Size,lengthOffset=rootOffset+IntPtr.Size,nameOffset=lengthOffset+4,size=nameOffset+name.Length+2;IntPtr buffer=Marshal.AllocHGlobal(size);bool parentAdded=false,sourceAdded=false;try{source.DangerousAddRef(ref sourceAdded);parent.DangerousAddRef(ref parentAdded);for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,0);Marshal.WriteIntPtr(buffer,rootOffset,parent.DangerousGetHandle());Marshal.WriteInt32(buffer,lengthOffset,name.Length);Marshal.Copy(name,0,IntPtr.Add(buffer,nameOffset),name.Length);IO_STATUS_BLOCK io;int status=NtSetInformationFile(source,out io,buffer,(uint)size,FileRenameInformation);return status>=0?0:(int)RtlNtStatusToDosError(status);}finally{if(parentAdded)parent.DangerousRelease();if(sourceAdded)source.DangerousRelease();Marshal.FreeHGlobal(buffer);}}
    private static int RenameReplacing(SafeFileHandle source,SafeFileHandle parent,string destination){byte[] name=Encoding.Unicode.GetBytes(destination);int rootOffset=IntPtr.Size,lengthOffset=rootOffset+IntPtr.Size,nameOffset=lengthOffset+4,size=nameOffset+name.Length+2;IntPtr buffer=Marshal.AllocHGlobal(size);bool parentAdded=false,sourceAdded=false;try{source.DangerousAddRef(ref sourceAdded);parent.DangerousAddRef(ref parentAdded);for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,1);Marshal.WriteIntPtr(buffer,rootOffset,parent.DangerousGetHandle());Marshal.WriteInt32(buffer,lengthOffset,name.Length);Marshal.Copy(name,0,IntPtr.Add(buffer,nameOffset),name.Length);IO_STATUS_BLOCK io;int status=NtSetInformationFile(source,out io,buffer,(uint)size,FileRenameInformation);return status>=0?0:(int)RtlNtStatusToDosError(status);}finally{if(parentAdded)parent.DangerousRelease();if(sourceAdded)source.DangerousRelease();Marshal.FreeHGlobal(buffer);}}
}
'@
        $marker = 'CcodInstallGenerationCapabilityMarkerV4' -as [type]
    }
    if ($null -eq $marker -or [int]$marker.GetProperty('CapabilityAbi').GetValue($null,$null) -ne 4) { Throw-CcodInstallFileError 'CCOD_INSTALL_RUNTIME_ABI_INVALID' 'Install generation runtime ABI is unavailable' $null }
    $script:CcodRuntimeType = $marker.Assembly.GetType('CcodInstallGenerationRuntimeV4',$true)
}

function Assert-CcodInstallLeaf([string]$Leaf,[string]$ErrorId='CCOD_INSTALL_LEAF_INVALID') {
    if ([string]::IsNullOrWhiteSpace($Leaf)-or$Leaf.Length-gt 160-or$Leaf-in@('.','..')-or$Leaf-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$'-or$Leaf.EndsWith('.')-or$Leaf-match'^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { Throw-CcodInstallFileError $ErrorId 'Unsafe install leaf' $Leaf }
}
function Invoke-CcodRuntimeStatic([string]$Name,[object[]]$Arguments){$method=$script:CcodRuntimeType.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static');try{return $method.Invoke($null,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}}
function Invoke-CcodRuntimeMethod($Runtime,[string]$Name,[object[]]$Arguments){$method=$Runtime.GetType().GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Instance');try{return $method.Invoke($Runtime,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}}
function New-CcodInstallCapability { New-Object psobject }
function Get-CcodInstallTransaction($Capability,[string]$InvalidId='CCOD_INSTALL_GENERATION_INVALID',[switch]$AllowRetired){$record=$null;if($null-eq$Capability-or-not$script:CcodScopes.TryGetValue($Capability,[ref]$record)){Throw-CcodInstallFileError $InvalidId 'Invalid install generation capability' $null};$state=$null;if(-not$script:CcodTransactions.TryGetValue($record.Transaction,[ref]$state)){Throw-CcodInstallFileError $InvalidId 'Invalid install transaction capability' $null};if($state.Closed){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' 'Install file transaction is closed' $null};if($state.Retired-and-not$AllowRetired){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_RETIRED' 'Install generation is retired' $null};[pscustomobject]@{State=$state;Record=$record}}
function Add-CcodInstallScope($Transaction,$Token,[string]$Kind='Directory',[bool]$ReadOnly=$false,[AllowNull()][string]$RuntimeId=$null){$capability=New-CcodInstallCapability;$script:CcodScopes.Add($capability,[pscustomobject]@{Transaction=$Transaction;Token=$Token;Kind=$Kind;ReadOnly=$ReadOnly;RuntimeId=$RuntimeId});$capability}
function Get-CcodInstallScopedDirectory($Transaction,$Parent){$parentScope=Get-CcodInstallTransaction $Parent 'CCOD_INSTALL_DIRECTORY_INVALID';if(-not[object]::ReferenceEquals($parentScope.Record.Transaction,$Transaction)-or$parentScope.Record.Kind-cnotin@('Directory','Generation')){Throw-CcodInstallFileError 'CCOD_INSTALL_DIRECTORY_INVALID' 'Directory capability is outside the transaction scope' $null};return $parentScope}
function Assert-CcodInstallWritableScope($Scope){if($Scope.Record.ReadOnly){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_READ_ONLY' 'Retained generation capability is read-only' $null}}
function Convert-CcodInstallRuntimeError($Action,[string]$DefaultId){try{return&$Action}catch{$exception=$_.Exception;while($null-ne$exception.InnerException-and$exception-is[Management.Automation.RuntimeException]){$exception=$exception.InnerException};$message=[string]$exception.Message;if($exception-is[ObjectDisposedException]){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' $message $null};if($message-match'state-only scope'){Throw-CcodInstallFileError 'CCOD_INSTALL_STATE_SCOPE' $message $null};if($message-match'product-only scope'){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SCOPE' $message $null};if($exception-is[ComponentModel.Win32Exception]-and$exception.NativeErrorCode-in@(80,183)){Throw-CcodInstallFileError 'CCOD_INSTALL_LEAF_EXISTS' 'Install object already exists' $null};if($message-match'pointer generation exists'){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_GENERATION_EXISTS' $message $null};if($message-match'pointer generation overflow'){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_GENERATION_OVERFLOW' $message $null};if($message-match'retained manifest mismatch'){Throw-CcodInstallFileError 'CCOD_INSTALL_RETAINED_MANIFEST_MISMATCH' $message $null};if($message-match'retained runtime id mismatch'){Throw-CcodInstallFileError 'CCOD_INSTALL_RETAINED_RUNTIME_ID_MISMATCH' $message $null};if($message-match'product shortcut source'){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID' $message $null};if($message-match'seal mismatch'){Throw-CcodInstallFileError 'CCOD_INSTALL_SEAL_MISMATCH' $message $null};if($message-match'alternate stream'){Throw-CcodInstallFileError 'CCOD_INSTALL_ADS_LEAF' $message $null};if($message-match'multi-link'){Throw-CcodInstallFileError 'CCOD_INSTALL_MULTILINK_LEAF' $message $null};if($message-match'reparse'){Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' $message $null};if($message-match'transaction scope'){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_SCOPE' $message $null};if($message-match'generation not owned'){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_NOT_OWNED' $message $null};if($message-match'unknown|unsealed'){Throw-CcodInstallFileError 'CCOD_INSTALL_UNKNOWN_LEAF' $message $null};if($message-match'pin changed|path changed'){Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' $message $null};Throw-CcodInstallFileError $DefaultId $message $null}}
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
function Get-CcodInstallBytesSha256([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Get-CcodTopLevelJsonPropertyCount([string]$Json,[string]$Name){$count=0;$depth=0;$inString=$false;$escaped=$false;$expectKey=$false;$captureKey=$false;$keyStart=-1;for($index=0;$index-lt$Json.Length;$index++){$character=$Json[$index];if($inString){if($escaped){$escaped=$false;continue};if($character-ceq'\'){$escaped=$true;continue};if($character-ceq'"'){if($captureKey){try{$key=$Json.Substring($keyStart,$index-$keyStart+1)|ConvertFrom-Json -ErrorAction Stop}catch{return -1};if($key-isnot[string]){return -1};if($key-ceq$Name){$count++};$expectKey=$false};$inString=$false;$captureKey=$false};continue};if($character-ceq'"'){$inString=$true;$captureKey=($depth-eq 1-and$expectKey);if($captureKey){$keyStart=$index};continue};if($character-ceq'{'-or$character-ceq'['){$depth++;if($depth-eq 1-and$character-ceq'{'){$expectKey=$true};continue};if($character-ceq'}'-or$character-ceq']'){$depth--;continue};if($character-ceq','-and$depth-eq 1){$expectKey=$true}};if($inString-or$depth-ne 0){return -1};return $count}
function Test-CcodRetainedManifestIdentity([string]$Json,[string]$RuntimeId){try{$manifest=$Json|ConvertFrom-Json -ErrorAction Stop}catch{return $false};if($manifest-isnot[pscustomobject]-or(Get-CcodTopLevelJsonPropertyCount $Json 'runtimeId')-ne 1){return $false};$properties=@($manifest.PSObject.Properties|Where-Object Name -CEQ 'runtimeId');return ($properties.Count-eq 1-and$properties[0].Value-is[string]-and[string]$properties[0].Value-ceq$RuntimeId)}
function Assert-CcodInstallRootScope($State,[string]$InstallRoot,[string]$ErrorId){if(-not[IO.Path]::IsPathRooted($InstallRoot)-or-not[String]::Equals([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\'),$State.InstallRoot,[StringComparison]::OrdinalIgnoreCase)){Throw-CcodInstallFileError $ErrorId 'Install root does not match transaction scope' $InstallRoot}}

function Open-CcodInstallGeneration {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId)
    Initialize-CcodInstallRuntime;if(-not[IO.Path]::IsPathRooted($InstallRoot)){Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root must be absolute' $InstallRoot};Assert-CcodInstallLeaf $RuntimeId 'CCOD_INSTALL_RUNTIME_ID_INVALID'
    $arguments=[object[]]@([IO.Path]::GetFullPath($InstallRoot),$RuntimeId,$null)
    try{$token=Invoke-CcodRuntimeStatic Open $arguments}catch [ComponentModel.Win32Exception]{if($_.Exception.NativeErrorCode-in@(32,80,183)){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_EXISTS' 'Install generation already exists' $RuntimeId};throw}
    $runtime=$arguments[2];$transaction=New-CcodInstallCapability;$script:CcodTransactions.Add($transaction,[pscustomobject]@{Runtime=$runtime;InstallRoot=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\');RuntimeId=$RuntimeId;RootToken=$token;StateOnly=$false;ProductOnly=$false;Closed=$false;CleanupFailed=$false;Retired=$false;RetirementResult=$null;Disposition=$null});$script:CcodScopes.Add($transaction,[pscustomobject]@{Transaction=$transaction;Token=$token;Kind='Generation';ReadOnly=$false;RuntimeId=$RuntimeId});$transaction
}
function Open-CcodInstallStateTransaction { param([Parameter(Mandatory)][string]$InstallRoot) Initialize-CcodInstallRuntime;if(-not[IO.Path]::IsPathRooted($InstallRoot)){Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root must be absolute' $InstallRoot};$arguments=[object[]]@([IO.Path]::GetFullPath($InstallRoot),$null);$token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeStatic OpenState $arguments} 'CCOD_INSTALL_STATE_TRANSACTION_INVALID';$runtime=$arguments[1];$transaction=New-CcodInstallCapability;$script:CcodTransactions.Add($transaction,[pscustomobject]@{Runtime=$runtime;InstallRoot=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\');RuntimeId=$null;RootToken=$token;StateOnly=$true;ProductOnly=$false;Closed=$false;CleanupFailed=$false;Retired=$false;RetirementResult=$null;Disposition=$null});$script:CcodScopes.Add($transaction,[pscustomobject]@{Transaction=$transaction;Token=$token;Kind='StateTransaction';ReadOnly=$false;RuntimeId=$null});$transaction }
function Open-CcodInstallProductRegistrationTransaction {param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)]$ReadyEvidence)Initialize-CcodInstallRuntime;if(-not[IO.Path]::IsPathRooted($InstallRoot)){Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root must be absolute' $InstallRoot};$properties=@($ReadyEvidence.PSObject.Properties);$names=@('phase','runtimeId','runtimeGeneration','manifestSha256','packageSha256');if($properties.Count-ne$names.Count-or(@($properties.Name)-join'|')-cne($names-join'|')-or$ReadyEvidence.phase-cne'Ready'-or$ReadyEvidence.runtimeId-isnot[string]-or[uint64]$ReadyEvidence.runtimeGeneration-lt1-or$ReadyEvidence.manifestSha256-cnotmatch'^[0-9a-f]{64}$'-or$ReadyEvidence.packageSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SCOPE' 'Product transaction requires exact Ready evidence' $ReadyEvidence};$root=[IO.Path]::GetFullPath($InstallRoot);$pointerRoot=Join-Path $root 'state\active-generation';$pointerLeaves=@(Get-ChildItem -LiteralPath $pointerRoot -File -Force -ErrorAction Stop|Sort-Object Name);if($pointerLeaves.Count-eq0-or$pointerLeaves[-1].Name-cne('{0:D20}.json'-f[uint64]$ReadyEvidence.runtimeGeneration)){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SCOPE' 'Ready evidence is not the latest selected generation' $ReadyEvidence};$pointerPath=Join-Path $root ('state\active-generation\{0:D20}.json'-f[uint64]$ReadyEvidence.runtimeGeneration);$manifestPath=Join-Path (Join-Path (Join-Path $root 'runtime') $ReadyEvidence.runtimeId) 'manifest.json';try{$pointer=Get-Content -LiteralPath $pointerPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if([string]$pointer.activeRuntime-cne[string]$ReadyEvidence.runtimeId-or[uint64]$pointer.generation-ne[uint64]$ReadyEvidence.runtimeGeneration-or(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()-cne[string]$ReadyEvidence.manifestSha256){throw 'selected pointer or manifest mismatch'};$matches=@();foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'state\install-transactions') -File -Force -ErrorAction Stop)){try{$record=Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if($record.phase-ceq'Ready'-and$record.newRuntimeId-ceq$ReadyEvidence.runtimeId-and[uint64]$record.newGeneration-eq[uint64]$ReadyEvidence.runtimeGeneration-and$record.newManifestSha256-ceq$ReadyEvidence.manifestSha256-and$record.sealedPackageSha256-ceq$ReadyEvidence.packageSha256){$matches+=,$record}}catch{throw}};if($matches.Count-ne1){throw 'matching Ready record missing or ambiguous'}}catch{Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SCOPE' 'Selected pointer manifest and Ready record could not be proven' $ReadyEvidence};$arguments=[object[]]@($root,$null);$token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeStatic OpenProduct $arguments} 'CCOD_INSTALL_PRODUCT_SCOPE';$runtime=$arguments[1];$transaction=New-CcodInstallCapability;$script:CcodTransactions.Add($transaction,[pscustomobject]@{Runtime=$runtime;InstallRoot=$root.TrimEnd('\');RuntimeId=$ReadyEvidence.runtimeId;RootToken=$token;StateOnly=$false;ProductOnly=$true;ReadyEvidence=$ReadyEvidence;Closed=$false;CleanupFailed=$false;Retired=$false;RetirementResult=$null;Disposition=$null});$script:CcodScopes.Add($transaction,[pscustomobject]@{Transaction=$transaction;Token=$token;Kind='ProductTransaction';ReadOnly=$true;RuntimeId=$ReadyEvidence.runtimeId});$transaction}
function Open-CcodInstallRetainedGeneration { param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)][string]$ExpectedManifestSha256,[Parameter(Mandatory)]$FileTransaction) if(-not[IO.Path]::IsPathRooted($InstallRoot)-or$ExpectedManifestSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_RETAINED_GENERATION_INVALID' 'Invalid retained generation contract' $RuntimeId};Assert-CcodInstallLeaf $RuntimeId 'CCOD_INSTALL_RUNTIME_ID_INVALID';$scope=Get-CcodInstallTransaction $FileTransaction 'CCOD_INSTALL_TRANSACTION_INVALID';if(-not[object]::ReferenceEquals($scope.Record.Transaction,$FileTransaction)){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'FileTransaction must be the transaction root capability' $null};Assert-CcodInstallRootScope $scope.State $InstallRoot 'CCOD_INSTALL_TRANSACTION_SCOPE';$nativeResult=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime OpenRetained @($RuntimeId,$ExpectedManifestSha256)} 'CCOD_INSTALL_RETAINED_GENERATION_INVALID';if(@($nativeResult).Count-ne 2-or-not(Test-CcodRetainedManifestIdentity ([string]$nativeResult[1]) $RuntimeId)){Throw-CcodInstallFileError 'CCOD_INSTALL_RETAINED_RUNTIME_ID_MISMATCH' 'Retained manifest must contain exactly one matching top-level runtimeId string' $RuntimeId};Add-CcodInstallScope $scope.Record.Transaction $nativeResult[0] Generation $true $RuntimeId }
function Open-CcodInstallRetainedFile {param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)]$ReadyEvidence)if($RelativePath-cnotin@('registration/StartMenu.CodexRemote-fix.lnk','registration/Desktop.CodexRemote-fix.lnk')){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID' 'Product shortcut source must be one fixed manifest-relative candidate' $RelativePath};$scope=Get-CcodInstallTransaction $Generation 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID';if($ReadyEvidence.phase-cne'Ready'-or$ReadyEvidence.runtimeId-cne$scope.Record.RuntimeId-or[uint64]$ReadyEvidence.runtimeGeneration-lt1-or$ReadyEvidence.manifestSha256-cnotmatch'^[0-9a-f]{64}$'-or$ReadyEvidence.packageSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SCOPE' 'Retained shortcut source lacks exact Ready selection evidence' $ReadyEvidence};$root=$scope.State.InstallRoot;$pointer=Get-Content -LiteralPath (Join-Path $root ('state\active-generation\{0:D20}.json'-f[uint64]$ReadyEvidence.runtimeGeneration)) -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if($pointer.activeRuntime-cne$ReadyEvidence.runtimeId-or[uint64]$pointer.generation-ne[uint64]$ReadyEvidence.runtimeGeneration){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SCOPE' 'Retained shortcut source is not selected' $ReadyEvidence};$result=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime OpenRetainedFile @($scope.Record.Token,$RelativePath)} 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID';if(@($result).Count-ne3-or[int64]$result[1]-lt0-or[string]$result[2]-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID' 'Retained product shortcut identity is invalid' $RelativePath};Add-CcodInstallScope $scope.Record.Transaction $result[0] RetainedFile $true $scope.Record.RuntimeId}
function New-CcodInstallDirectory { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$Parent,[Parameter(Mandatory)][string]$Leaf,[switch]$CreateIfMissing) Assert-CcodInstallLeaf $Leaf;$transactionScope=Get-CcodInstallTransaction $Transaction 'CCOD_INSTALL_TRANSACTION_INVALID';if(-not[object]::ReferenceEquals($transactionScope.Record.Transaction,$Transaction)){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Transaction capability must be the transaction root' $null};if([object]::ReferenceEquals($Parent,$Transaction)){$token=Invoke-CcodRuntimeMethod $transactionScope.State.Runtime GetInstallRoot @();$parentScope=[pscustomobject]@{State=$transactionScope.State;Record=[pscustomobject]@{Transaction=$Transaction;Token=$token;Kind='Directory';ReadOnly=$false;RuntimeId=$null}}}else{$parentScope=Get-CcodInstallScopedDirectory $Transaction $Parent};Assert-CcodInstallWritableScope $parentScope;$token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $parentScope.State.Runtime OpenDirectory @($parentScope.Record.Token,$Leaf,[bool]$CreateIfMissing)} 'CCOD_INSTALL_DIRECTORY_OPEN_FAILED';$readOnly=[bool](Invoke-CcodRuntimeMethod $parentScope.State.Runtime IsRetained @($token));Add-CcodInstallScope $Transaction $token Directory $readOnly $(if($readOnly){$parentScope.Record.RuntimeId}else{$null}) }
function New-CcodInstallGenerationLeaf { param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)][string]$Leaf) Assert-CcodInstallLeaf $Leaf;$scope=Get-CcodInstallTransaction $Generation;Assert-CcodInstallWritableScope $scope;if($scope.State.StateOnly){Throw-CcodInstallFileError 'CCOD_INSTALL_STATE_SCOPE' 'State-only transaction cannot create a generation leaf' $Leaf};$token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime CreateDirectory @($scope.Record.Token,$Leaf)} 'CCOD_INSTALL_LEAF_CREATE_FAILED';Add-CcodInstallScope $scope.Record.Transaction $token Directory $scope.Record.ReadOnly $scope.Record.RuntimeId }
function Copy-CcodInstallSealedSource { param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)][int64]$ExpectedLength,[Parameter(Mandatory)][string]$ExpectedSha256) Assert-CcodInstallLeaf $Leaf;if(-not[IO.Path]::IsPathRooted($SourcePath)-or$ExpectedLength-lt 0-or$ExpectedSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_INVALID' 'Invalid sealed source contract' $SourcePath};$scope=Get-CcodInstallTransaction $Generation;Assert-CcodInstallWritableScope $scope;$result=[pscustomobject]@{Length=$ExpectedLength;Sha256=$ExpectedSha256};Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Copy @($scope.Record.Token,$Leaf,[IO.Path]::GetFullPath($SourcePath),$ExpectedLength,$ExpectedSha256)|Out-Null} 'CCOD_INSTALL_SOURCE_MISMATCH';return $result }
function Write-CcodInstallGenerationManifest { param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)]$Manifest) $scope=Get-CcodInstallTransaction $Generation;Assert-CcodInstallWritableScope $scope;if($scope.Record.Token-ne$scope.State.RootToken){Throw-CcodInstallFileError 'CCOD_INSTALL_MANIFEST_SCOPE' 'Manifest must be written at the generation root' $null};$bytes=ConvertTo-CcodInstallJsonBytes $Manifest;$result=[pscustomobject]@{Length=[int64]$bytes.LongLength;Sha256=(Get-CcodInstallBytesSha256 $bytes)};Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Write @($scope.Record.Token,'manifest.json',$bytes,$true)|Out-Null} 'CCOD_INSTALL_MANIFEST_WRITE_FAILED';return $result }
function Write-CcodInstallRecord { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$Parent,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)]$Record) Assert-CcodInstallLeaf $Leaf;$scope=Get-CcodInstallScopedDirectory $Transaction $Parent;Assert-CcodInstallWritableScope $scope;$bytes=ConvertTo-CcodInstallJsonBytes $Record;$result=[pscustomobject]@{Length=[int64]$bytes.LongLength;Sha256=(Get-CcodInstallBytesSha256 $bytes)};try{Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Write @($scope.Record.Token,$Leaf,$bytes,$false)|Out-Null} 'CCOD_INSTALL_RECORD_WRITE_FAILED'}catch{if($_.FullyQualifiedErrorId-like'CCOD_INSTALL_LEAF_EXISTS*'){Throw-CcodInstallFileError 'CCOD_INSTALL_RECORD_EXISTS' 'Install record already exists' $Leaf};throw};return $result }
function Commit-CcodInstallActivePointer { param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)]$TargetGeneration,[Parameter(Mandatory)][uint64]$ExpectedPreviousGeneration,[Parameter(Mandatory)]$FileTransaction) if($ExpectedPreviousGeneration-eq[uint64]::MaxValue){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_GENERATION_OVERFLOW' 'Pointer generation cannot advance beyond UInt64.MaxValue' $ExpectedPreviousGeneration};$scope=Get-CcodInstallTransaction $FileTransaction 'CCOD_INSTALL_TRANSACTION_INVALID';Assert-CcodInstallRootScope $scope.State $InstallRoot 'CCOD_INSTALL_TRANSACTION_SCOPE';$target=Get-CcodInstallTransaction $TargetGeneration 'CCOD_INSTALL_POINTER_TARGET_INVALID';if(-not[object]::ReferenceEquals($target.Record.Transaction,$FileTransaction)-or$target.Record.Kind-cne'Generation'-or[string]::IsNullOrWhiteSpace([string]$target.Record.RuntimeId)){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_TARGET_INVALID' 'Pointer target is outside the transaction scope' $null};$generation=[uint64]($ExpectedPreviousGeneration+1);$runtimeId=[string]$target.Record.RuntimeId;$pointer=[ordered]@{schemaVersion=1;generation=$generation;activeRuntime=$runtimeId;previousGeneration=$ExpectedPreviousGeneration};$bytes=ConvertTo-CcodInstallJsonBytes $pointer;$result=[pscustomobject]@{Generation=$generation;RuntimeId=$runtimeId};try{Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime CommitPointer @($target.Record.Token,$ExpectedPreviousGeneration,$runtimeId,$bytes)|Out-Null} 'CCOD_INSTALL_POINTER_COMMIT_FAILED'}catch{if($_.FullyQualifiedErrorId-like'CCOD_INSTALL_LEAF_EXISTS*'){Throw-CcodInstallFileError 'CCOD_INSTALL_POINTER_GENERATION_EXISTS' 'Pointer generation already exists' $generation};throw};return $result }
function Retire-CcodInstallGeneration { param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)]$FileTransaction) Assert-CcodInstallLeaf $RuntimeId 'CCOD_INSTALL_RUNTIME_ID_INVALID';$scope=Get-CcodInstallTransaction $FileTransaction 'CCOD_INSTALL_TRANSACTION_INVALID' -AllowRetired;Assert-CcodInstallRootScope $scope.State $InstallRoot 'CCOD_INSTALL_TRANSACTION_SCOPE';if($RuntimeId-cne$scope.State.RuntimeId-or$scope.Record.Token-ne$scope.State.RootToken){Throw-CcodInstallFileError 'CCOD_INSTALL_GENERATION_NOT_OWNED' 'Generation is not owned by this transaction' $RuntimeId};if($scope.State.Retired){return $scope.State.RetirementResult};$recordLeaf=$RuntimeId+'.json';$record=ConvertTo-CcodInstallJsonBytes ([ordered]@{schemaVersion=1;runtimeId=$RuntimeId;state='Retired'});$capability=Add-CcodInstallScope $scope.Record.Transaction $scope.State.RootToken;$result=[pscustomobject]@{Disposition='Retired';Capability=$capability};try{Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime Retire @($scope.Record.Token,$RuntimeId,$recordLeaf,$record)|Out-Null} 'CCOD_INSTALL_RETIREMENT_FAILED'}catch{if($_.FullyQualifiedErrorId-like'CCOD_INSTALL_LEAF_EXISTS*'){Throw-CcodInstallFileError 'CCOD_INSTALL_RETIREMENT_RECORD_EXISTS' 'Retirement record already exists' $recordLeaf};throw};$scope.State.RetirementResult=$result;$scope.State.Retired=$true;return $result }
function Open-CcodInstallProductSpecialFolder {
    param([Parameter(Mandatory)]$Generation,[Parameter(Mandatory)][ValidateSet('StartMenu','Desktop')][string]$Kind)
    $scope=Get-CcodInstallTransaction $Generation 'CCOD_INSTALL_TRANSACTION_INVALID'
    if($scope.Record.Kind-cne'Generation'-or[string]::IsNullOrWhiteSpace([string]$scope.Record.RuntimeId)-or$scope.State.StateOnly){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_FOLDER_INVALID' 'Product special folder requires a generation or retained-generation capability' $Kind}
    $specialFolder=if($Kind-ceq'StartMenu'){[Environment+SpecialFolder]::Programs}else{[Environment+SpecialFolder]::Desktop}
    $path=[Environment]::GetFolderPath($specialFolder)
    if([string]::IsNullOrWhiteSpace($path)-or-not[IO.Path]::IsPathRooted($path)){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_FOLDER_INVALID' 'Current-user special folder is unavailable' $Kind}
    $token=Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime OpenProductFolder @($Kind,[IO.Path]::GetFullPath($path))} 'CCOD_INSTALL_PRODUCT_FOLDER_INVALID'
    Add-CcodInstallScope $scope.Record.Transaction $token ProductFolder $false $scope.Record.RuntimeId
}
function Copy-CcodInstallProductShortcut {
    param([Parameter(Mandatory)]$Folder,[Parameter(Mandatory)]$Source,[Parameter(Mandatory)][ValidateSet('StartMenu','Desktop')][string]$Kind,[Parameter(Mandatory)][string]$Leaf)
    if($Leaf-cne'CodexRemote-fix.lnk'){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID' 'Invalid fixed product shortcut contract' $Leaf}
    $scope=Get-CcodInstallTransaction $Folder 'CCOD_INSTALL_PRODUCT_FOLDER_INVALID';$sourceScope=Get-CcodInstallTransaction $Source 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID';if($scope.Record.Kind-cne'ProductFolder'-or$sourceScope.Record.Kind-cne'RetainedFile'-or-not[object]::ReferenceEquals($scope.Record.Transaction,$sourceScope.Record.Transaction)-or$scope.Record.RuntimeId-cne$sourceScope.Record.RuntimeId){Throw-CcodInstallFileError 'CCOD_INSTALL_PRODUCT_SHORTCUT_INVALID' 'Product shortcut source and destination are outside one selected generation scope' $Kind}
    Convert-CcodInstallRuntimeError {Invoke-CcodRuntimeMethod $scope.State.Runtime CopyProductShortcut @($scope.Record.Token,$Kind,$sourceScope.Record.Token,$Leaf)} 'CCOD_INSTALL_PRODUCT_SHORTCUT_FAILED'|Out-Null
    [pscustomobject]@{Kind=$Kind;Leaf=$Leaf}
}
function Close-CcodInstallFileTransaction { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)][ValidateSet('Ready','Failed')][string]$Disposition) $state=$null;if($null-eq$Transaction-or-not$script:CcodTransactions.TryGetValue($Transaction,[ref]$state)){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Invalid install file transaction capability' $null};if($state.Closed-and-not$state.CleanupFailed){return};try{Invoke-CcodRuntimeMethod $state.Runtime Close @()|Out-Null;$state.CleanupFailed=$false}catch{$state.CleanupFailed=$true;$state.Closed=$true;$state.Disposition=$Disposition;Throw-CcodInstallFileError 'CCOD_INSTALL_CLOSE_FAILED' 'Install file transaction cleanup failed; registered failures are retained for retry' $null};$state.Closed=$true;$state.Disposition=$Disposition }

Initialize-CcodInstallRuntime
Export-ModuleMember -Function Open-CcodInstallGeneration,Open-CcodInstallStateTransaction,Open-CcodInstallProductRegistrationTransaction,Open-CcodInstallRetainedGeneration,Open-CcodInstallRetainedFile,New-CcodInstallDirectory,New-CcodInstallGenerationLeaf,Copy-CcodInstallSealedSource,Write-CcodInstallGenerationManifest,Write-CcodInstallRecord,Commit-CcodInstallActivePointer,Retire-CcodInstallGeneration,Open-CcodInstallProductSpecialFolder,Copy-CcodInstallProductShortcut,Close-CcodInstallFileTransaction
