[CmdletBinding()]
param(
    [switch]$ProtocolOnly,
    [switch]$NativeOnly,
    [switch]$TransportOnly,
    [switch]$ParentClientOnly,
    [switch]$ProductionOnly
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if((@($ProtocolOnly,$NativeOnly,$TransportOnly,$ParentClientOnly,$ProductionOnly)|Where-Object{$_}).Count -ne 1){throw 'CCOD_TRAYHOST_TEST_MODE_REQUIRED'}
$protocolPath=Join-Path $repositoryRoot 'src\trayhost\PipeProtocol.cs'
$presentationPath=Join-Path $repositoryRoot 'src\trayhost\PresentationSnapshot.cs'
$nativeFiles=@(
    (Join-Path $repositoryRoot 'src\trayhost\AssemblyInfo.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\NativeMethods.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\InputModeGuard.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\NativeMenu.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\TrayWindow.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\TrayHostApplication.cs')
)
$transportFiles=@(
    (Join-Path $repositoryRoot 'src\trayhost\TransportMessages.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\ParentTransport.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\HostTransport.cs')
)
$protocolSupportFiles=@(
    (Join-Path $repositoryRoot 'src\trayhost\TransportMessages.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\TrayHostWire.cs')
)
$parentClientFiles=@(
    (Join-Path $repositoryRoot 'src\trayhost\TrayHostWire.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\JobObject.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\TrayHostParentClient.cs')
)
$testPath=if($ProtocolOnly){Join-Path $repositoryRoot 'tests\trayhost\TrayHostProtocolSelfTest.cs'}elseif($NativeOnly){Join-Path $repositoryRoot 'tests\trayhost\TrayHostNativeSelfTest.cs'}elseif($TransportOnly){Join-Path $repositoryRoot 'tests\trayhost\TrayHostTransportSelfTest.cs'}else{Join-Path $repositoryRoot 'tests\trayhost\TrayHostParentClientSelfTest.cs'}
$requiredFiles=@($protocolPath,$presentationPath,$testPath)
if($ProtocolOnly){$requiredFiles+=$protocolSupportFiles}
if($NativeOnly){$requiredFiles+=$nativeFiles}
if($TransportOnly){$requiredFiles+=$transportFiles}
if($ParentClientOnly){$requiredFiles+=$transportFiles+$parentClientFiles}
if($ProductionOnly){$requiredFiles+=(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src\trayhost') -Filter '*.cs' -File | ForEach-Object FullName)}
if($requiredFiles|Where-Object{ -not(Test-Path -LiteralPath $_ -PathType Leaf)}){throw 'CCOD_TRAYHOST_SOURCE_MISSING'}
Import-Module (Join-Path $repositoryRoot 'build\TrayHostReferencePack.psm1') -Force
$reference=Resolve-CcodTrayHostReferencePack -LockPath (Join-Path $repositoryRoot 'build\trayhost-packages.lock.json') -CacheRoot (Join-Path $env:TEMP 'ccod-trayhost-reference-pack')
$compilerCandidates=@((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
$compiler=$compilerCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if($null -eq $compiler){throw 'CCOD_TRAYHOST_COMPILER_MISSING'}
$temporaryRoot=Join-Path $env:TEMP ('ccod-trayhost-protocol-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporaryRoot -Force|Out-Null
try{
    $outputName=if($ProtocolOnly){'TrayHostProtocolSelfTest.exe'}elseif($NativeOnly){'TrayHostNativeSelfTest.exe'}elseif($TransportOnly){'TrayHostTransportSelfTest.exe'}elseif($ParentClientOnly){'TrayHostParentClientSelfTest.exe'}else{'CodexRemote.TrayHost.exe'}
    $mainType=if($ProtocolOnly){'TrayHostProtocolSelfTest'}elseif($NativeOnly){'TrayHostNativeSelfTest'}elseif($TransportOnly){'TrayHostTransportSelfTest'}elseif($ParentClientOnly){'TrayHostParentClientSelfTest'}else{'Program'}
    $outputPath=Join-Path $temporaryRoot $outputName
    $args=@('/nologo','/noconfig','/nostdlib+','/target:exe','/platform:anycpu','/optimize+','/checked+','/warn:4','/warnaserror+',('/out:{0}' -f $outputPath),('/main:{0}' -f $mainType))
    foreach($leaf in @('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll')){$args+=('/reference:'+ (Join-Path $reference.ReferenceRoot $leaf))}
    if($ProductionOnly){$args+=(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src\trayhost') -Filter '*.cs' -File | ForEach-Object FullName)}
    else
    {
        $args+=@($protocolPath,$presentationPath)
        if($ProtocolOnly){$args+=$protocolSupportFiles}
        if($NativeOnly){$args+=$nativeFiles}
        if($TransportOnly){$args+=$transportFiles}
        if($ParentClientOnly){$args+=$transportFiles+$parentClientFiles}
    }
    $args+=$testPath
    & $compiler @args
    if($LASTEXITCODE -ne 0){if($ProtocolOnly){throw 'CCOD_TRAYHOST_PROTOCOL_COMPILE_FAILED'}elseif($ProductionOnly){throw 'CCOD_TRAYHOST_PRODUCTION_COMPILE_FAILED'}else{throw 'CCOD_TRAYHOST_NATIVE_COMPILE_FAILED'}}
    if($ProductionOnly){& $outputPath '--headless-smoke'}else{& $outputPath}
    if($LASTEXITCODE -ne 0){if($ProtocolOnly){throw 'CCOD_TRAYHOST_PROTOCOL_TEST_FAILED'}elseif($ProductionOnly){throw 'CCOD_TRAYHOST_HEADLESS_SMOKE_FAILED'}else{throw 'CCOD_TRAYHOST_NATIVE_TEST_FAILED'}}
}finally{if(Test-Path -LiteralPath $temporaryRoot){Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue}}
