Set-StrictMode -Version Latest

$script:CcodTransactions = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()
$script:CcodPins = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()

function Throw-CcodInstallFileError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Initialize-CcodInstallRuntime {
    if ($null -eq ('CcodInstallCapabilityMarker' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CcodInstallCapabilityMarker { private CcodInstallCapabilityMarker() {} public static int CapabilityAbi { get { return 1; } } }

internal sealed class CcodInstallRuntime : IDisposable
{
    private const uint READ = 0x80000000, WRITE = 0x40000000, DELETE = 0x00010000, READ_CONTROL = 0x00020000, WRITE_DAC = 0x00040000, SYNC = 0x00100000;
    private const uint READ_ATTRIBUTES = 0x80, LIST_DIRECTORY = 0x1, ADD_FILE = 0x2, ADD_SUBDIRECTORY = 0x4;
    private const uint SHARE_READ = 1, SHARE_WRITE = 2, SHARE_DELETE = 4;
    private const uint OPEN = 1, CREATE = 2, OPEN_IF = 3;
    private const uint DIRECTORY = 1, WRITE_THROUGH = 2, SYNC_IO = 0x20, NON_DIRECTORY = 0x40, BACKUP_INTENT = 0x4000, OPEN_REPARSE = 0x200000;
    private const uint FLAG_BACKUP = 0x02000000, FLAG_REPARSE = 0x00200000, FLAG_WRITE_THROUGH = 0x80000000;
    private const uint OPEN_EXISTING = 3, OBJ_CASE_INSENSITIVE = 0x40, ATTR_DIRECTORY = 0x10, ATTR_REPARSE = 0x400;
    private const int FileRenameInformation = 10, FileDispositionInformation = 13, FileStreamInfo = 7, FileDirectoryInformation = 1;
    private const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);
    private const uint DACL_SECURITY_INFORMATION = 0x00000004, PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000, UNPROTECTED_DACL_SECURITY_INFORMATION = 0x20000000;

    [StructLayout(LayoutKind.Sequential)] private struct UNICODE_STRING { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] private struct IO_STATUS_BLOCK { public IntPtr Status; public UIntPtr Information; }
    [StructLayout(LayoutKind.Sequential)] private struct FILETIME_NATIVE { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] private struct FILE_INFO
    {
        public uint FileAttributes; public FILETIME_NATIVE CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle h,out FILE_INFO i);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder b,uint l,uint f);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int c,IntPtr i,uint s);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetFileInformationByHandle(SafeFileHandle h,int c,IntPtr i,uint s);
    [DllImport("ntdll.dll")] private static extern int NtCreateFile(out IntPtr h,uint a,ref OBJECT_ATTRIBUTES o,out IO_STATUS_BLOCK i,IntPtr z,uint fa,uint sh,uint d,uint op,IntPtr e,uint el);
    [DllImport("ntdll.dll")] private static extern int NtQueryDirectoryFile(SafeFileHandle h,IntPtr e,IntPtr a,IntPtr c,out IO_STATUS_BLOCK i,IntPtr f,uint l,int cl,bool one,IntPtr n,bool restart);
    [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle h,out IO_STATUS_BLOCK i,IntPtr f,uint l,int cl);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int s);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetKernelObjectSecurity(SafeFileHandle h,uint i,byte[] sd,uint length,out uint needed);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool SetKernelObjectSecurity(SafeFileHandle h,uint i,byte[] sd);

    private sealed class Pin : IDisposable
    {
        internal readonly object Token = new object(); internal readonly Pin Parent; internal string Leaf, Path;
        internal readonly bool Directory, Owned; internal SafeFileHandle Handle; internal FileStream Stream; internal byte[] OriginalSecurity; internal bool RestoreSecurity;
        internal readonly uint Volume; internal readonly ulong Index; internal bool Closed, Sealed; internal long SealedLength; internal string SealedSha;
        internal Pin(Pin parent,string leaf,string path,bool dir,bool owned,SafeFileHandle handle,FileStream stream,FILE_INFO info)
        { Parent=parent;Leaf=leaf;Path=path;Directory=dir;Owned=owned;Handle=handle;Stream=stream;Volume=info.VolumeSerialNumber;Index=((ulong)info.FileIndexHigh<<32)|info.FileIndexLow; }
        internal SafeFileHandle Native { get { return Stream != null ? Stream.SafeFileHandle : Handle; } }
        public void Dispose() { if(Closed)return; Closed=true; if(RestoreSecurity&&Handle!=null)RestoreDirectorySecurity(Handle,OriginalSecurity);if(Stream!=null)Stream.Dispose(); else if(Handle!=null)Handle.Dispose(); }
    }

    private readonly string rootPath; private readonly Pin root;
    private readonly Dictionary<object,Pin> pins = new Dictionary<object,Pin>(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<string,Pin> names = new Dictionary<string,Pin>(StringComparer.OrdinalIgnoreCase);
    private bool disposed;

    private sealed class ReferenceEqualityComparer : IEqualityComparer<object>
    { internal static readonly ReferenceEqualityComparer Instance=new ReferenceEqualityComparer(); public new bool Equals(object x,object y){return Object.ReferenceEquals(x,y);} public int GetHashCode(object x){return System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(x);} }

    private CcodInstallRuntime(string path,Pin rootPin) { rootPath=path;root=rootPin;pins.Add(root.Token,root); }
    internal static object Open(string path,out CcodInstallRuntime runtime)
    {
        runtime=null; string full=Path.GetFullPath(path).TrimEnd('\\');
        SafeFileHandle h=CreateFileW(full,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,FLAG_BACKUP|FLAG_REPARSE,IntPtr.Zero);
        if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
        try { FILE_INFO i=Info(h); if(!IsDirectory(i)||(i.FileAttributes&ATTR_REPARSE)!=0||!SamePath(FinalPath(h),full))throw new InvalidDataException("root invalid");if(!OnlyDefaultStream(h))throw new InvalidDataException("alternate stream");
            Pin p=new Pin(null,"",full,true,false,h,null,i); h=null; runtime=new CcodInstallRuntime(full,p); return p.Token; }
        finally { if(h!=null)h.Dispose(); }
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object OpenDirectory(object parentToken,string leaf,bool create)
    {
        Pin parent=Require(parentToken,true); ValidateCurrent(parent); string key=Key(parent,leaf); Pin known; if(names.TryGetValue(key,out known)){ValidateCurrent(known);return known.Token;}
        OpenResult r=null;
        if(create){try{r=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|READ_CONTROL|WRITE_DAC|SYNC,SHARE_READ,CREATE,DIRECTORY|BACKUP_INTENT);}catch(Win32Exception x){if(x.NativeErrorCode!=80&&x.NativeErrorCode!=183)throw;r=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);}}
        else r=OpenRelative(parent.Native,leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,SHARE_READ|SHARE_WRITE,OPEN,DIRECTORY|BACKUP_INTENT);
        try { FILE_INFO i=Info(r.Handle); if(!IsDirectory(i)||(i.FileAttributes&ATTR_REPARSE)!=0||!OnlyDefaultStream(r.Handle))throw new InvalidDataException("directory invalid");
            string path=Path.Combine(parent.Path,leaf); if(!SamePath(FinalPath(r.Handle),path))throw new InvalidDataException("path changed");
            Pin p=new Pin(parent,leaf,path,true,r.Created,r.Handle,null,i);r.Handle=null;AddPin(key,p);return p.Token; }
        finally { if(r.Handle!=null)r.Handle.Dispose(); }
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object CreateTemporary(object parentToken,string leaf)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);string key=Key(parent,leaf);if(names.ContainsKey(key))throw new IOException("exists");
        OpenResult r=OpenRelative(parent.Native,leaf,READ|WRITE|DELETE|SYNC,SHARE_READ,CREATE,NON_DIRECTORY|WRITE_THROUGH);
        FileStream s=null;try{s=new FileStream(r.Handle,FileAccess.ReadWrite,65536,false);r.Handle=null;FILE_INFO i=Info(s.SafeFileHandle);ValidatePlain(i,s.SafeFileHandle);Pin p=new Pin(parent,leaf,Path.Combine(parent.Path,leaf),false,true,null,s,i);s=null;AddPin(key,p);return p.Token;}
        finally{if(s!=null)s.Dispose();if(r.Handle!=null)r.Handle.Dispose();}
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object Copy(object destinationToken,string source,long expectedLength,string expectedSha)
    {
        Pin d=Require(destinationToken,false);ValidateCurrent(d);if(!d.Owned)throw new InvalidDataException("destination not owned");
        string full=Path.GetFullPath(source); SafeFileHandle sh=CreateFileW(full,READ|READ_ATTRIBUTES|SYNC,SHARE_READ,IntPtr.Zero,OPEN_EXISTING,FLAG_REPARSE,IntPtr.Zero);if(sh.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
        try{FILE_INFO si=Info(sh);ValidatePlain(si,sh);if(!SamePath(FinalPath(sh),full))throw new InvalidDataException("source path");using(FileStream ss=new FileStream(sh,FileAccess.Read,65536,false)){sh=null;if(ss.Length!=expectedLength||Sha(ss)!=expectedSha)throw new InvalidDataException("source mismatch");ss.Position=0;d.Stream.Position=0;d.Stream.SetLength(0);ss.CopyTo(d.Stream);d.Stream.Flush(true);string actual=Sha(d.Stream);if(d.Stream.Length!=expectedLength||actual!=expectedSha)throw new InvalidDataException("destination mismatch");d.Sealed=true;d.SealedLength=expectedLength;d.SealedSha=expectedSha;}}finally{if(sh!=null)sh.Dispose();}
        return d.Token;
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object Promote(object parentToken,object tempToken,string destination)
    {
        Pin parent=Require(parentToken,true),temp=Require(tempToken,false);ValidateCurrent(parent);ValidateCurrent(temp);
        if(temp.Parent!=parent||!temp.Owned||!temp.Sealed)throw new InvalidDataException("promotion invalid");
        if(temp.Stream.Length!=temp.SealedLength||Sha(temp.Stream)!=temp.SealedSha)throw new CryptographicException("seal mismatch");
        SafeFileHandle existing=null;try{try{existing=OpenRelative(parent.Native,destination,READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,BACKUP_INTENT).Handle;}catch(Win32Exception x){if(x.NativeErrorCode!=2&&x.NativeErrorCode!=3)throw;}if(existing!=null)throw new IOException("destination exists");}
        finally{if(existing!=null)existing.Dispose();}
        int ec=Rename(temp.Native,parent.Native,destination);if(ec==80||ec==183)throw new IOException("destination exists");if(ec!=0)throw new Win32Exception(ec);names.Remove(Key(parent,temp.Leaf));temp.Leaf=destination;temp.Path=Path.Combine(parent.Path,destination);names.Add(Key(parent,destination),temp);MakeReadable(temp);ValidateCurrent(temp);return temp.Token;
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object WriteJson(object parentToken,string leaf,byte[] bytes)
    { Pin parent=Require(parentToken,true);ValidateCurrent(parent);object t=CreateTemporary(parentToken,".json."+Guid.NewGuid().ToString("N")+".tmp");Pin p=Require(t,false);Write(p,bytes);p.Sealed=true;p.SealedLength=bytes.LongLength;p.SealedSha=Sha(p.Stream);return Promote(parentToken,t,leaf); }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object Append(object parentToken,string leaf,byte[] bytes)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);string key=Key(parent,leaf);Pin p;
        if(!names.TryGetValue(key,out p)){OpenResult r=OpenRelative(parent.Native,leaf,READ|WRITE|DELETE|SYNC,SHARE_READ,OPEN_IF,NON_DIRECTORY|WRITE_THROUGH);FileStream s=null;try{s=new FileStream(r.Handle,FileAccess.ReadWrite,65536,false);r.Handle=null;FILE_INFO i=Info(s.SafeFileHandle);ValidatePlain(i,s.SafeFileHandle);p=new Pin(parent,leaf,Path.Combine(parent.Path,leaf),false,r.Created,null,s,i);s=null;AddPin(key,p);}finally{if(s!=null)s.Dispose();if(r.Handle!=null)r.Handle.Dispose();}}
        ValidateCurrent(p);p.Stream.Position=p.Stream.Length;p.Stream.Write(bytes,0,bytes.Length);p.Stream.Flush(true);return p.Token;
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal object RemoveOwnedTree(object parentToken,string leaf)
    {return RemoveOwnedTreeCore(parentToken,leaf,".__ccod_retired_"+Guid.NewGuid().ToString("N"));}
    [MethodImpl(MethodImplOptions.Synchronized)] private object RemoveOwnedTreeCore(object parentToken,string leaf,string retiredLeaf)
    {
        Pin parent=Require(parentToken,true);ValidateCurrent(parent);Pin target;string key=Key(parent,leaf);if(!names.TryGetValue(key,out target)||!target.Owned||!target.Directory)throw new InvalidDataException("unknown target");
        List<Pin> plan=new List<Pin>();BuildPlan(target,plan);RevalidatePlan(target,plan);
        if(plan.Count==0){int ec=SetDeleteOnClose(target.Native,true,true);if(ec!=0)throw new Win32Exception(ec);ValidateCurrent(target);RemovePin(target);return null;}
        SafeFileHandle collision=null;try{try{collision=OpenRelative(parent.Native,retiredLeaf,READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,BACKUP_INTENT).Handle;}catch(Win32Exception x){if(x.NativeErrorCode!=2&&x.NativeErrorCode!=3)throw;}if(collision!=null)throw new IOException("retirement destination exists");}finally{if(collision!=null)collision.Dispose();}
        List<Pin> restricted=RestrictRetirementTree(target,plan);try{RevalidatePlan(target,plan);}catch{RestoreLiveDirectorySecurity(restricted);throw;}ReleaseDescendants(plan);ValidateCurrent(target);int rec=Rename(target.Native,parent.Native,retiredLeaf);if(rec!=0){RestoreDirectorySecurity(target.Native,target.OriginalSecurity);target.RestoreSecurity=false;RestoreReleasedChildSecurity(target);ReopenKnownTree(target);if(rec==80||rec==183)throw new IOException("retirement destination exists");throw new Win32Exception(rec);}MoveDirectoryPin(target,retiredLeaf,Path.Combine(parent.Path,retiredLeaf));RestoreReleasedChildSecurity(target);ValidateCurrent(target);return target.Token;
    }
    [MethodImpl(MethodImplOptions.Synchronized)] internal void Close(){if(disposed)return;disposed=true;List<Pin> all=new List<Pin>(pins.Values);for(int i=all.Count-1;i>=0;i--)all[i].Dispose();pins.Clear();names.Clear();}
    public void Dispose(){Close();}

    private void BuildPlan(Pin dir,List<Pin> plan){ValidateCurrent(dir);foreach(string n in Enumerate(dir.Native)){Pin p;string k=Key(dir,n);if(!names.TryGetValue(k,out p)||!p.Owned){ProbeUnknown(dir,n);throw new InvalidDataException("unknown leaf");}ValidateCurrent(p);if(p.Directory)BuildPlan(p,plan);plan.Add(p);}}
    private static void ProbeUnknown(Pin dir,string name){OpenResult r=OpenRelative(dir.Native,name,READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,BACKUP_INTENT);try{FILE_INFO i=Info(r.Handle);if((i.FileAttributes&ATTR_REPARSE)!=0)throw new InvalidDataException("reparse leaf");if(!OnlyDefaultStream(r.Handle))throw new InvalidDataException("alternate stream");if(!IsDirectory(i)&&i.NumberOfLinks!=1)throw new InvalidDataException("multi-link");}finally{r.Handle.Dispose();}}
    private void RevalidatePlan(Pin target,List<Pin> plan){List<Pin> second=new List<Pin>();BuildPlan(target,second);if(second.Count!=plan.Count)throw new InvalidDataException("namespace changed");for(int i=0;i<plan.Count;i++)if(!Object.ReferenceEquals(plan[i],second[i]))throw new InvalidDataException("namespace changed");foreach(Pin p in plan){ValidateCurrent(p);if(p.Directory&&(Info(p.Native).FileAttributes&1)!=0)throw new Win32Exception(5);}ValidateCurrent(target);if((Info(target.Native).FileAttributes&1)!=0)throw new Win32Exception(5);}
    private void RemovePin(Pin p){string k=Key(p.Parent,p.Leaf);p.Dispose();pins.Remove(p.Token);names.Remove(k);}
    private void MoveDirectoryPin(Pin dir,string newLeaf,string newPath){string oldKey=Key(dir.Parent,dir.Leaf),oldPath=dir.Path;names.Remove(oldKey);dir.Leaf=newLeaf;dir.Path=newPath;names.Add(Key(dir.Parent,newLeaf),dir);string prefix=oldPath.TrimEnd('\\')+"\\";foreach(Pin p in pins.Values)if(!Object.ReferenceEquals(p,dir)&&p.Path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase))p.Path=newPath+"\\"+p.Path.Substring(prefix.Length);}
    private static void ReleaseDescendants(List<Pin> plan){foreach(Pin p in plan){if(p.Stream!=null){p.Stream.Dispose();p.Stream=null;}else if(p.Handle!=null){p.Handle.Dispose();p.Handle=null;}}}
    private void ReopenKnownTree(Pin dir){List<Pin> children=new List<Pin>();foreach(Pin p in pins.Values)if(Object.ReferenceEquals(p.Parent,dir)&&!p.Closed)children.Add(p);foreach(Pin p in children){if(p.Directory){uint share=p.Owned?SHARE_READ:(SHARE_READ|SHARE_WRITE);OpenResult r=OpenRelative(dir.Native,p.Leaf,LIST_DIRECTORY|ADD_FILE|ADD_SUBDIRECTORY|READ_ATTRIBUTES|DELETE|SYNC,share,OPEN,DIRECTORY|BACKUP_INTENT);p.Handle=r.Handle;ValidateCurrent(p);ReopenKnownTree(p);}else{OpenResult r=OpenRelative(dir.Native,p.Leaf,READ|WRITE|DELETE|SYNC,SHARE_READ,OPEN,NON_DIRECTORY|WRITE_THROUGH);p.Stream=new FileStream(r.Handle,FileAccess.ReadWrite,65536,false);r.Handle=null;ValidateCurrent(p);}}}
    private static void MakeReadable(Pin p){OpenResult bridge=OpenRelative(p.Parent.Native,p.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE|SHARE_DELETE,OPEN,NON_DIRECTORY);FILE_INFO bi=Info(bridge.Handle);if(bi.VolumeSerialNumber!=p.Volume||(((ulong)bi.FileIndexHigh<<32)|bi.FileIndexLow)!=p.Index){bridge.Handle.Dispose();throw new InvalidDataException("pin changed");}p.Stream.Dispose();p.Stream=null;OpenResult strict=OpenRelative(p.Parent.Native,p.Leaf,READ|READ_ATTRIBUTES|SYNC,SHARE_READ|SHARE_WRITE,OPEN,NON_DIRECTORY);bridge.Handle.Dispose();p.Stream=new FileStream(strict.Handle,FileAccess.Read,65536,false);strict.Handle=null;}
    private Pin Require(object token,bool directory){if(disposed)throw new ObjectDisposedException("transaction");Pin p;if(token==null||!pins.TryGetValue(token,out p)||p.Closed||p.Directory!=directory)throw new InvalidDataException("invalid capability");return p;}
    private void AddPin(string key,Pin p){pins.Add(p.Token,p);names.Add(key,p);}
    private static byte[] ReadDirectorySecurity(SafeFileHandle h){uint needed;GetKernelObjectSecurity(h,DACL_SECURITY_INFORMATION,null,0,out needed);int e=Marshal.GetLastWin32Error();if(needed==0)throw new Win32Exception(e);byte[] sd=new byte[needed];if(!GetKernelObjectSecurity(h,DACL_SECURITY_INFORMATION,sd,(uint)sd.Length,out needed))throw new Win32Exception(Marshal.GetLastWin32Error());return sd;}
    private static byte[] RestrictRetirementDirectory(SafeFileHandle h){byte[] original=ReadDirectorySecurity(h);RawSecurityDescriptor raw=new RawSecurityDescriptor(original,0);RawAcl acl=raw.DiscretionaryAcl??new RawAcl(GenericAcl.AclRevision,1);int denyMask=0x00000002|0x00000004|0x00000010|0x00000040|0x00000100|0x00010000;acl.InsertAce(0,new CommonAce(AceFlags.None,AceQualifier.AccessDenied,denyMask,new SecurityIdentifier(WellKnownSidType.WorldSid,null),false,null));raw.DiscretionaryAcl=acl;raw.SetFlags(raw.ControlFlags|ControlFlags.DiscretionaryAclPresent|ControlFlags.DiscretionaryAclProtected);byte[] restricted=new byte[raw.BinaryLength];raw.GetBinaryForm(restricted,0);if(!SetKernelObjectSecurity(h,DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION,restricted))throw new Win32Exception(Marshal.GetLastWin32Error());return original;}
    private static void RestoreDirectorySecurity(SafeFileHandle h,byte[] original){if(original==null)return;RawSecurityDescriptor raw=new RawSecurityDescriptor(original,0);uint flags=DACL_SECURITY_INFORMATION|(((raw.ControlFlags&ControlFlags.DiscretionaryAclProtected)!=0)?PROTECTED_DACL_SECURITY_INFORMATION:UNPROTECTED_DACL_SECURITY_INFORMATION);if(!SetKernelObjectSecurity(h,flags,original))throw new Win32Exception(Marshal.GetLastWin32Error());}
    private static List<Pin> RestrictRetirementTree(Pin target,List<Pin> plan){List<Pin> restricted=new List<Pin>();try{target.OriginalSecurity=RestrictRetirementDirectory(target.Native);target.RestoreSecurity=true;restricted.Add(target);foreach(Pin p in plan)if(p.Directory){p.OriginalSecurity=RestrictRetirementDirectory(p.Native);p.RestoreSecurity=true;restricted.Add(p);}return restricted;}catch{RestoreLiveDirectorySecurity(restricted);throw;}}
    private static void RestoreLiveDirectorySecurity(List<Pin> restricted){for(int i=restricted.Count-1;i>=0;i--){Pin p=restricted[i];RestoreDirectorySecurity(p.Native,p.OriginalSecurity);p.RestoreSecurity=false;p.OriginalSecurity=null;}}
    private void RestoreReleasedChildSecurity(Pin dir){List<Pin> children=new List<Pin>();foreach(Pin p in pins.Values)if(Object.ReferenceEquals(p.Parent,dir)&&p.Directory&&!p.Closed)children.Add(p);foreach(Pin child in children){OpenResult r=OpenRelative(dir.Native,child.Leaf,READ_ATTRIBUTES|READ_CONTROL|WRITE_DAC|SYNC,SHARE_READ|SHARE_WRITE|SHARE_DELETE,OPEN,DIRECTORY|BACKUP_INTENT);RestoreDirectorySecurity(r.Handle,child.OriginalSecurity);child.RestoreSecurity=false;child.OriginalSecurity=null;child.Handle=r.Handle;RestoreReleasedChildSecurity(child);child.Handle.Dispose();child.Handle=null;}}
    private static string Key(Pin p,string leaf){return p.Index.ToString("x16")+"|"+leaf.ToLowerInvariant();}
    private static void Write(Pin p,byte[] b){p.Stream.Position=0;p.Stream.SetLength(0);p.Stream.Write(b,0,b.Length);p.Stream.Flush(true);}
    private static void ValidateCurrent(Pin p){FILE_INFO i=Info(p.Native);if(i.VolumeSerialNumber!=p.Volume||(((ulong)i.FileIndexHigh<<32)|i.FileIndexLow)!=p.Index||IsDirectory(i)!=p.Directory||(i.FileAttributes&ATTR_REPARSE)!=0||!SamePath(FinalPath(p.Native),p.Path))throw new InvalidDataException("pin changed");if(!OnlyDefaultStream(p.Native))throw new InvalidDataException("alternate stream");if(!p.Directory&&i.NumberOfLinks!=1)throw new InvalidDataException("multi-link");}
    private static void ValidatePlain(FILE_INFO i,SafeFileHandle h){if(IsDirectory(i))throw new InvalidDataException("file type");if((i.FileAttributes&ATTR_REPARSE)!=0)throw new InvalidDataException("reparse leaf");if(i.NumberOfLinks!=1)throw new InvalidDataException("multi-link");if(!OnlyDefaultStream(h))throw new InvalidDataException("alternate stream");}
    private static bool IsDirectory(FILE_INFO i){return(i.FileAttributes&ATTR_DIRECTORY)!=0;}
    private static FILE_INFO Info(SafeFileHandle h){FILE_INFO i;if(!GetFileInformationByHandle(h,out i))throw new Win32Exception(Marshal.GetLastWin32Error());return i;}
    private static string FinalPath(SafeFileHandle h){StringBuilder b=new StringBuilder(512);uint n=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0);if(n==0)throw new Win32Exception(Marshal.GetLastWin32Error());if(n>=b.Capacity){b.Capacity=(int)n+1;n=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0);if(n==0||n>=b.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());}string s=b.ToString();if(s.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return@"\\"+s.Substring(8);if(s.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))return s.Substring(4);return s;}
    private static bool SamePath(string a,string b){return String.Equals(Path.GetFullPath(a).TrimEnd('\\'),Path.GetFullPath(b).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);}
    private static string Sha(FileStream s){long p=s.Position;using(SHA256 h=SHA256.Create()){s.Position=0;string v=BitConverter.ToString(h.ComputeHash(s)).Replace("-","").ToLowerInvariant();s.Position=p;return v;}}
    private static bool OnlyDefaultStream(SafeFileHandle h){IntPtr b=Marshal.AllocHGlobal(65536);try{if(!GetFileInformationByHandleEx(h,FileStreamInfo,b,65536)){int e=Marshal.GetLastWin32Error();if(e==38)return true;throw new Win32Exception(e);}int o=0;while(true){uint nx=(uint)Marshal.ReadInt32(b,o),nl=(uint)Marshal.ReadInt32(b,o+4);string n=Marshal.PtrToStringUni(IntPtr.Add(b,o+24),(int)nl/2);if(!String.Equals(n,"::$DATA",StringComparison.OrdinalIgnoreCase)&&!String.Equals(n,"::$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase))return false;if(nx==0)break;o+=(int)nx;}return true;}finally{Marshal.FreeHGlobal(b);}}
    private static string[] Enumerate(SafeFileHandle h){List<string> r=new List<string>();IntPtr b=Marshal.AllocHGlobal(65536);bool restart=true;try{while(true){IO_STATUS_BLOCK io;int st=NtQueryDirectoryFile(h,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out io,b,65536,FileDirectoryInformation,false,IntPtr.Zero,restart);restart=false;if(st==STATUS_NO_MORE_FILES)break;if(st<0)throw new Win32Exception((int)RtlNtStatusToDosError(st));int o=0;while(true){uint nx=(uint)Marshal.ReadInt32(b,o),nl=(uint)Marshal.ReadInt32(b,o+60);string n=Marshal.PtrToStringUni(IntPtr.Add(b,o+64),(int)nl/2);if(n!="."&&n!="..")r.Add(n);if(nx==0)break;o+=(int)nx;}}return r.ToArray();}finally{Marshal.FreeHGlobal(b);}}
    private sealed class OpenResult{internal SafeFileHandle Handle;internal bool Created;internal OpenResult(SafeFileHandle h,bool c){Handle=h;Created=c;}}
    private static OpenResult OpenRelative(SafeFileHandle parent,string name,uint access,uint share,uint disposition,uint options)
    {IntPtr nb=IntPtr.Zero,up=IntPtr.Zero;bool add=false;try{parent.DangerousAddRef(ref add);nb=Marshal.StringToHGlobalUni(name);UNICODE_STRING u=new UNICODE_STRING{Length=(ushort)(name.Length*2),MaximumLength=(ushort)((name.Length+1)*2),Buffer=nb};up=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));Marshal.StructureToPtr(u,up,false);OBJECT_ATTRIBUTES o=new OBJECT_ATTRIBUTES{Length=Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)),RootDirectory=parent.DangerousGetHandle(),ObjectName=up,Attributes=OBJ_CASE_INSENSITIVE};IO_STATUS_BLOCK io;IntPtr raw;int st=NtCreateFile(out raw,access,ref o,out io,IntPtr.Zero,0,share,disposition,options|SYNC_IO|OPEN_REPARSE,IntPtr.Zero,0);if(st<0)throw new Win32Exception((int)RtlNtStatusToDosError(st));return new OpenResult(new SafeFileHandle(raw,true),io.Information.ToUInt64()==2);}finally{if(up!=IntPtr.Zero)Marshal.FreeHGlobal(up);if(nb!=IntPtr.Zero)Marshal.FreeHGlobal(nb);if(add)parent.DangerousRelease();}}
    private static int Rename(SafeFileHandle source,SafeFileHandle parent,string destination)
    {byte[] n=Encoding.Unicode.GetBytes(destination);int ro=IntPtr.Size,lo=ro+IntPtr.Size,no=lo+4,size=no+n.Length+2;IntPtr b=Marshal.AllocHGlobal(size);bool pa=false,sa=false;try{source.DangerousAddRef(ref sa);parent.DangerousAddRef(ref pa);for(int i=0;i<size;i++)Marshal.WriteByte(b,i,0);Marshal.WriteByte(b,0,0);Marshal.WriteIntPtr(b,ro,parent.DangerousGetHandle());Marshal.WriteInt32(b,lo,n.Length);Marshal.Copy(n,0,IntPtr.Add(b,no),n.Length);IO_STATUS_BLOCK io;int st=NtSetInformationFile(source,out io,b,(uint)size,FileRenameInformation);return st>=0?0:(int)RtlNtStatusToDosError(st);}finally{if(pa)parent.DangerousRelease();if(sa)source.DangerousRelease();Marshal.FreeHGlobal(b);}}
    private static int SetDelete(SafeFileHandle h,bool delete){IntPtr b=Marshal.AllocHGlobal(1);try{Marshal.WriteByte(b,delete?(byte)1:(byte)0);IO_STATUS_BLOCK io;int st=NtSetInformationFile(h,out io,b,1,FileDispositionInformation);return st>=0?0:(int)RtlNtStatusToDosError(st);}finally{Marshal.FreeHGlobal(b);}}
    private static int SetDeleteOnClose(SafeFileHandle h,bool delete,bool directory){IntPtr b=Marshal.AllocHGlobal(4);try{Marshal.WriteInt32(b,delete?1:0);return SetFileInformationByHandle(h,21,b,4)?0:Marshal.GetLastWin32Error();}finally{Marshal.FreeHGlobal(b);}}
}
'@
    }
    $script:CcodRuntimeType = [CcodInstallCapabilityMarker].Assembly.GetType('CcodInstallRuntime', $true)
}

function Assert-CcodLeaf([string]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf.Length -gt 160 -or $Leaf -in @('.','..') -or $Leaf -notmatch '^[A-Za-z0-9._-]+$' -or $Leaf.EndsWith('.') -or $Leaf -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { Throw-CcodInstallFileError 'CCOD_INSTALL_LEAF_INVALID' 'Unsafe install leaf' $Leaf }
}
function Invoke-CcodRuntimeStatic([string]$Name,[object[]]$Arguments) { $method=$script:CcodRuntimeType.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static');try{return $method.Invoke($null,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException} }
function Invoke-CcodRuntimeMethod($Runtime,[string]$Name,[object[]]$Arguments) { $method=$Runtime.GetType().GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Instance');try{return $method.Invoke($Runtime,$Arguments)}catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException} }
function Get-CcodTransactionState($Transaction) { $state=$null;if($null -eq $Transaction -or -not $script:CcodTransactions.TryGetValue($Transaction,[ref]$state)){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Invalid install transaction capability' $null};if($state.Closed){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' 'Install transaction is closed' $null};return $state }
function Get-CcodPinToken($Transaction,$Pin,[string]$Kind) { $state=Get-CcodTransactionState $Transaction;$record=$null;if($null -eq $Pin -or -not $script:CcodPins.TryGetValue($Pin,[ref]$record) -or -not [object]::ReferenceEquals($record.Transaction,$Transaction) -or $record.Kind -cne $Kind){Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_INVALID' 'Invalid install pin capability' $null};return [pscustomobject]@{State=$state;Token=$record.Token;Record=$record} }
function New-CcodCapability { New-Object psobject }
function Add-CcodPinCapability($Transaction,$Token,[string]$Kind) {$cap=New-CcodCapability;$script:CcodPins.Add($cap,[pscustomobject]@{Transaction=$Transaction;Token=$Token;Kind=$Kind});return $cap}
function Convert-CcodRuntimeError($Action,[string]$DefaultId) {
    try { return & $Action }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException -and $exception -is [Management.Automation.RuntimeException]) { $exception = $exception.InnerException }
        $message = [string]$exception.Message
        if ($message -ceq 'destination exists') { Throw-CcodInstallFileError 'CCOD_INSTALL_PROMOTION_DESTINATION_EXISTS' $message $null }
        if ($message -ceq 'retirement destination exists') { Throw-CcodInstallFileError 'CCOD_INSTALL_RETIREMENT_DESTINATION_EXISTS' $message $null }
        if ($exception -is [ObjectDisposedException]) { Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' $message $null }
        if ($exception -is [Security.Cryptography.CryptographicException] -or $message -match 'seal mismatch') { Throw-CcodInstallFileError 'CCOD_INSTALL_SEAL_MISMATCH' $message $null }
        if ($message -match 'alternate stream') { Throw-CcodInstallFileError 'CCOD_INSTALL_ADS_LEAF' $message $null }
        if ($message -match 'reparse') { Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' $message $null }
        if ($message -match 'multi-link') { Throw-CcodInstallFileError 'CCOD_INSTALL_MULTILINK_LEAF' $message $null }
        if ($message -match 'unknown|namespace') { Throw-CcodInstallFileError 'CCOD_INSTALL_UNKNOWN_LEAF' $message $null }
        if ($message -match 'pin changed|path changed') { Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' $message $null }
        Throw-CcodInstallFileError $DefaultId $message $null
    }
}

function Open-CcodInstallFileTransaction { param([Parameter(Mandatory)][string]$InstallRoot) Initialize-CcodInstallRuntime;if(-not [IO.Path]::IsPathRooted($InstallRoot)){Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root must be absolute' $InstallRoot};$arguments=[object[]]@([IO.Path]::GetFullPath($InstallRoot),$null);$root=Convert-CcodRuntimeError {Invoke-CcodRuntimeStatic Open $arguments} 'CCOD_INSTALL_ROOT_INVALID';$runtime=$arguments[1];$tx=New-CcodCapability;$rootCap=Add-CcodPinCapability $tx $root 'Directory';$tx|Add-Member -NotePropertyName RootDirectory -NotePropertyValue $rootCap;$script:CcodTransactions.Add($tx,[pscustomobject]@{Runtime=$runtime;Closed=$false;Root=$rootCap;Disposition=$null});return $tx }
function Open-CcodInstallPinnedDirectory { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$ParentDirectory,[Parameter(Mandatory)][string]$Leaf,[switch]$CreateIfMissing) Assert-CcodLeaf $Leaf;$p=Get-CcodPinToken $Transaction $ParentDirectory Directory;$token=Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime OpenDirectory @($p.Token,$Leaf,[bool]$CreateIfMissing)} 'CCOD_INSTALL_REPARSE_LEAF';return Add-CcodPinCapability $Transaction $token Directory }
function New-CcodInstallPinnedTemporaryLeaf { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$ParentDirectory,[Parameter(Mandatory)][string]$Leaf) Assert-CcodLeaf $Leaf;$p=Get-CcodPinToken $Transaction $ParentDirectory Directory;$token=Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime CreateTemporary @($p.Token,$Leaf)} 'CCOD_INSTALL_TEMPORARY_EXISTS';return Add-CcodPinCapability $Transaction $token File }
function Copy-CcodInstallSealedFile { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)]$DestinationLeaf,[Parameter(Mandatory)][int64]$ExpectedLength,[Parameter(Mandatory)][string]$ExpectedSha256) if(-not [IO.Path]::IsPathRooted($SourcePath)-or$ExpectedSha256-cnotmatch'^[0-9a-f]{64}$'){Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_INVALID' 'Invalid source contract' $SourcePath};$p=Get-CcodPinToken $Transaction $DestinationLeaf File;Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime Copy @($p.Token,[IO.Path]::GetFullPath($SourcePath),$ExpectedLength,$ExpectedSha256)|Out-Null} 'CCOD_INSTALL_SOURCE_MISMATCH';[pscustomobject]@{Length=$ExpectedLength;Sha256=$ExpectedSha256} }
function Commit-CcodInstallPinnedPromotion { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$ParentDirectory,[Parameter(Mandatory)]$TemporaryLeaf,[Parameter(Mandatory)][string]$DestinationLeaf) Assert-CcodLeaf $DestinationLeaf;$p=Get-CcodPinToken $Transaction $ParentDirectory Directory;$t=Get-CcodPinToken $Transaction $TemporaryLeaf File;$newToken=Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime Promote @($p.Token,$t.Token,$DestinationLeaf)} 'CCOD_INSTALL_PROMOTION_FAILED';$t.Record.Token=$newToken;return $TemporaryLeaf }
function Write-CcodInstallPinnedJson { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$ParentDirectory,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)]$Value,[switch]$Compress) Assert-CcodLeaf $Leaf;$p=Get-CcodPinToken $Transaction $ParentDirectory Directory;$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 32 -Compress:$Compress)+"`n");$token=Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime WriteJson @($p.Token,$Leaf,$bytes)} 'CCOD_INSTALL_PROMOTION_FAILED';return Add-CcodPinCapability $Transaction $token File }
function Test-CcodSanitized($Value,[int]$Depth=0) {
    if ($Depth -gt 8) { return $false }
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return ($Value.Length -le 4096) }
    if ($Value -is [ValueType]) { return $true }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or $key -cnotmatch '^[A-Za-z0-9_.-]{1,96}$' -or -not (Test-CcodSanitized $Value[$key] ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -cnotmatch '^[A-Za-z0-9_.-]{1,96}$' -or -not (Test-CcodSanitized $property.Value ($Depth + 1))) { return $false }
        }
        return $true
    }
    return $false
}
function Append-CcodInstallPinnedLog { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$ParentDirectory,[Parameter(Mandatory)][string]$Leaf,[Parameter(Mandatory)]$Record) Assert-CcodLeaf $Leaf;if(-not(Test-CcodSanitized $Record)){Throw-CcodInstallFileError 'CCOD_INSTALL_LOG_RECORD_INVALID' 'Invalid log record' $null};$p=Get-CcodPinToken $Transaction $ParentDirectory Directory;$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Record|ConvertTo-Json -Depth 8 -Compress)+"`n");if($bytes.Length-gt65536){Throw-CcodInstallFileError 'CCOD_INSTALL_LOG_RECORD_INVALID' 'Log record too large' $null};$token=Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime Append @($p.Token,$Leaf,$bytes)} 'CCOD_INSTALL_LOG_WRITE_FAILED';return Add-CcodPinCapability $Transaction $token File }
function Remove-CcodInstallOwnedTree { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$ParentDirectory,[Parameter(Mandatory)][string]$Leaf) Assert-CcodLeaf $Leaf;$p=Get-CcodPinToken $Transaction $ParentDirectory Directory;$token=Convert-CcodRuntimeError {Invoke-CcodRuntimeMethod $p.State.Runtime RemoveOwnedTree @($p.Token,$Leaf)} 'CCOD_INSTALL_RETIREMENT_FAILED';if($null -eq $token){return [pscustomobject]@{Disposition='Deleted';Object=$null}};$capability=Add-CcodPinCapability $Transaction $token Directory;return [pscustomobject]@{Disposition='Retired';Object=$capability} }
function Close-CcodInstallFileTransaction { param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)][ValidateSet('Ready','Failed')][string]$Disposition) $state=$null;if($null-eq$Transaction-or-not$script:CcodTransactions.TryGetValue($Transaction,[ref]$state)){Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Invalid install transaction capability' $null};if(-not$state.Closed){Invoke-CcodRuntimeMethod $state.Runtime Close @()|Out-Null;$state.Closed=$true;$state.Disposition=$Disposition} }

Export-ModuleMember -Function Open-CcodInstallFileTransaction,Open-CcodInstallPinnedDirectory,New-CcodInstallPinnedTemporaryLeaf,Copy-CcodInstallSealedFile,Commit-CcodInstallPinnedPromotion,Write-CcodInstallPinnedJson,Append-CcodInstallPinnedLog,Remove-CcodInstallOwnedTree,Close-CcodInstallFileTransaction
