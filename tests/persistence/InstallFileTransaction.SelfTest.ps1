$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $projectRoot 'src\persistence\modules\InstallFileTransaction.psm1'
$module = Import-Module $modulePath -Force -PassThru -DisableNameChecking

if ($null -eq ('CcodInstallFileRaceProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

public sealed class CcodInstallHandoffAttack : IDisposable
{
    private readonly CancellationTokenSource stop = new CancellationTokenSource();
    private readonly ManualResetEventSlim ready = new ManualResetEventSlim(false);
    private readonly Task<string>[] workers;
    public CcodInstallHandoffAttack(string path,string replacement)
    {
        workers=new Task<string>[16];
        for(int i=0;i<workers.Length;i++)workers[i]=Task.Run(() => { ready.Set();while(!stop.IsCancellationRequested){try{string backup=path+".attacker."+Guid.NewGuid().ToString("N");File.Move(path,backup);try{File.Copy(replacement,path);}catch(IOException){}catch(UnauthorizedAccessException){}stop.Cancel();return "exchanged";}catch(IOException){}catch(UnauthorizedAccessException){}}return "blocked";});
    }
    public bool WaitReady(int milliseconds){return ready.Wait(milliseconds);}
    public string Stop()
    {
        stop.Cancel();Task.WaitAll(workers);foreach(Task<string> worker in workers)if(worker.Result=="exchanged")return "exchanged";return "blocked";
    }
    public void Dispose(){Stop();stop.Dispose();ready.Dispose();}
}

public static class CcodInstallFileRaceProbe
{
    public static Task<byte[]> ObserveFirstVisibleBytes(string path)
    {
        return Task.Run(() => {DateTime deadline=DateTime.UtcNow.AddSeconds(15);while(DateTime.UtcNow<deadline){try{using(FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){byte[] bytes=new byte[stream.Length];int offset=0;while(offset<bytes.Length){int read=stream.Read(bytes,offset,bytes.Length-offset);if(read==0)break;offset+=read;}return bytes;}}catch(FileNotFoundException){}catch(DirectoryNotFoundException){}catch(IOException){}Thread.Yield();}throw new TimeoutException("final leaf never became visible");});
    }
    public static string RaceCreateAndClose(object runtime,object token,string leaf)
    {
        Type type=runtime.GetType();MethodInfo create=type.GetMethod("CreateDirectory",BindingFlags.Instance|BindingFlags.NonPublic);MethodInfo close=type.GetMethod("Close",BindingFlags.Instance|BindingFlags.NonPublic);Barrier barrier=new Barrier(2);string createResult=null,closeResult=null;
        Task first=Task.Run(() => {barrier.SignalAndWait();try{create.Invoke(runtime,new object[]{token,leaf});createResult="created";}catch(TargetInvocationException e){createResult=e.InnerException is ObjectDisposedException?"closed":e.InnerException.GetType().Name;}});
        Task second=Task.Run(() => {barrier.SignalAndWait();try{close.Invoke(runtime,new object[0]);closeResult="closed";}catch(TargetInvocationException e){closeResult=e.InnerException.GetType().Name;}});
        Task.WaitAll(first,second);barrier.Dispose();return createResult+"|"+closeResult;
    }
}
'@
}

function New-CcodInstallFileFixture {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('ccod-install-file-' + [guid]::NewGuid().ToString('N'))
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-install-outside-' + [guid]::NewGuid().ToString('N'))
    $install = Join-Path $base 'install'
    [IO.Directory]::CreateDirectory($install) | Out-Null
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $sentinel = Join-Path $outside 'sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'outside-sentinel-v1')
    [pscustomobject]@{ Base=$base; Outside=$outside; Install=$install; Sentinel=$sentinel; SentinelSha256=(Get-CcodTestFileSha256 $sentinel); Transactions=[Collections.Generic.List[object]]::new() }
}

function Remove-CcodInstallFileFixture {
    param([Parameter(Mandatory)]$Fixture)
    foreach ($transaction in @($Fixture.Transactions)) { try { Close-CcodInstallFileTransaction -Transaction $transaction -Disposition Failed | Out-Null } catch { } }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    foreach ($candidate in @($Fixture.Base,$Fixture.Outside)) {
        $full = [IO.Path]::GetFullPath([string]$candidate)
        if (-not $full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove non-temporary fixture path: $full" }
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    }
}

function Open-CcodFixtureGeneration {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$RuntimeId)
    $generation = Open-CcodInstallGeneration -InstallRoot $Fixture.Install -RuntimeId $RuntimeId
    $Fixture.Transactions.Add($generation)
    $generation
}

function New-CcodSourceFile {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Content)
    $path = Join-Path $Fixture.Base $Name
    [IO.File]::WriteAllText($path,$Content)
    [pscustomobject]@{ Path=$path; Length=[int64](Get-Item -LiteralPath $path).Length; Sha256=(Get-CcodTestFileSha256 $path) }
}

function New-CcodGenerationManifest {
    param([Parameter(Mandatory)][string]$RuntimeId,[object[]]$Files=@())
    [ordered]@{ schemaVersion=1; projectVersion='2.5.22'; runtimeId=$RuntimeId; commit='0123456789abcdef0123456789abcdef01234567'; files=@($Files) }
}

function Assert-CcodOutsideUnchanged {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$Message)
    Assert-CcodTrue ([IO.File]::Exists($Fixture.Sentinel)) "$Message sentinel exists"
    Assert-CcodEqual $Fixture.SentinelSha256 (Get-CcodTestFileSha256 $Fixture.Sentinel) "$Message sentinel bytes"
}

function Invoke-CcodMoveAttempt {
    param([Parameter(Mandatory)][string]$Path)
    try { [IO.File]::Move($Path,$Path+'.moved'); 'moved' } catch [IO.IOException] { 'blocked' } catch [UnauthorizedAccessException] { 'blocked' }
}

function New-CcodJunction {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Target)
    $previous=$ErrorActionPreference
    try { $ErrorActionPreference='Continue'; $output=& cmd.exe /d /c mklink /J $Path $Target 2>&1; $exitCode=$LASTEXITCODE } finally { $ErrorActionPreference=$previous }
    if($exitCode-ne 0){throw "Could not create junction: $($output -join ' ')"}
}

function New-CcodHardLink {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Existing)
    $previous=$ErrorActionPreference
    try { $ErrorActionPreference='Continue'; $output=& cmd.exe /d /c mklink /H $Path $Existing 2>&1; $exitCode=$LASTEXITCODE } finally { $ErrorActionPreference=$previous }
    if($exitCode-ne 0){throw "Could not create hard link: $($output -join ' ')"}
}

Invoke-CcodTest 'exports only immutable generation operations and an inert CLR marker' {
    $expected=@('Close-CcodInstallFileTransaction','Commit-CcodInstallActivePointer','Copy-CcodInstallSealedSource','New-CcodInstallGenerationLeaf','Open-CcodInstallGeneration','Retire-CcodInstallGeneration','Write-CcodInstallGenerationManifest')
    Assert-CcodEqual ($expected -join '|') ((@($module.ExportedCommands.Keys)|Sort-Object)-join '|') 'module export surface is capability-only'
    Assert-CcodEqual 2 ([CcodInstallGenerationCapabilityMarkerV2]::CapabilityAbi) 'marker exposes the current non-mutating ABI value'
    Assert-CcodEqual 'CcodInstallGenerationCapabilityMarkerV2' ((@([CcodInstallGenerationCapabilityMarkerV2].Assembly.GetExportedTypes()|ForEach-Object FullName)) -join '|') 'current CLR bridge exports only the inert marker'
    $dangerous=@([CcodInstallGenerationCapabilityMarkerV2].GetMethods([Reflection.BindingFlags]'Public,Static,DeclaredOnly')|Where-Object{@($_.GetParameters()|Where-Object{$_.ParameterType-in@([string],[IntPtr],[IO.Stream])-or[Microsoft.Win32.SafeHandles.SafeHandle].IsAssignableFrom($_.ParameterType)}).Count-ne 0})
    Assert-CcodEqual 0 $dangerous.Count 'marker accepts no path stream or bare handle'
}

Invoke-CcodTest 'force re-import rebinds the current runtime ABI before real use' {
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    $module = Import-Module $modulePath -Force -PassThru -DisableNameChecking
    $fixture = New-CcodInstallFileFixture
    try {
        $generation = Open-CcodFixtureGeneration $fixture 'runtime-reimport'
        $child = New-CcodInstallGenerationLeaf -Generation $generation -Leaf 'child'
        Assert-CcodEqual '' (@($child.PSObject.Properties.Name) -join ',') 'second import uses the current runtime type binding'
    } finally { Remove-CcodInstallFileFixture $fixture }
}

Invoke-CcodTest 'generation and capabilities are unique create-only opaque references' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-unique-a';$source=New-CcodSourceFile $fixture 'first.bin' 'first-generation-bytes';$generation=Open-CcodFixtureGeneration $fixture $runtimeId
        Assert-CcodEqual '' (@($generation.PSObject.Properties.Name)-join ',') 'generation capability exposes no fields'
        Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null
        $payload=Join-Path $fixture.Install "runtime\$runtimeId\payload.bin";$before=Get-CcodTestFileSha256 $payload
        Assert-CcodThrows {Open-CcodInstallGeneration -InstallRoot $fixture.Install -RuntimeId $runtimeId|Out-Null} 'CCOD_INSTALL_GENERATION_EXISTS'
        Assert-CcodEqual $before (Get-CcodTestFileSha256 $payload) 'duplicate generation leaves existing bytes unchanged'
        $child=New-CcodInstallGenerationLeaf -Generation $generation -Leaf 'child'
        Assert-CcodEqual '' (@($child.PSObject.Properties.Name)-join ',') 'child capability exposes no fields'
        Assert-CcodThrows {New-CcodInstallGenerationLeaf -Generation $generation -Leaf 'child'|Out-Null} 'CCOD_INSTALL_LEAF_EXISTS'
        Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install "runtime\$runtimeId\child"))) 'duplicate child keeps existing directory'
        Assert-CcodOutsideUnchanged $fixture 'duplicate generation and directory'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'destination collisions preserve the first object byte-for-byte' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-destination-collision';$first=New-CcodSourceFile $fixture 'first.bin' 'first-object';$second=New-CcodSourceFile $fixture 'second.bin' 'second-object';$generation=Open-CcodFixtureGeneration $fixture $runtimeId
        Copy-CcodInstallSealedSource -Generation $generation -SourcePath $first.Path -Leaf 'payload.bin' -ExpectedLength $first.Length -ExpectedSha256 $first.Sha256|Out-Null
        Assert-CcodThrows {Copy-CcodInstallSealedSource -Generation $generation -SourcePath $second.Path -Leaf 'payload.bin' -ExpectedLength $second.Length -ExpectedSha256 $second.Sha256|Out-Null} 'CCOD_INSTALL_LEAF_EXISTS'
        Assert-CcodEqual $first.Sha256 (Get-CcodTestFileSha256 (Join-Path $fixture.Install "runtime\$runtimeId\payload.bin")) 'collision never overwrites the first object'
        Assert-CcodOutsideUnchanged $fixture 'destination collision'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'requested final leaf is absent until private temporary bytes are sealed' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-private-until-sealed';$source=New-CcodSourceFile $fixture 'large-source.bin' ('private-source-block-'*1048576);$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$final=Join-Path $fixture.Install "runtime\$runtimeId\payload.bin"
        $observer=[CcodInstallFileRaceProbe]::ObserveFirstVisibleBytes($final)
        Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null
        $firstVisible=$observer.GetAwaiter().GetResult()
        Assert-CcodEqual $source.Length ([int64]$firstVisible.LongLength) 'first observable final leaf already has the sealed length'
        $observedPath=Join-Path $fixture.Base 'observed.bin';[IO.File]::WriteAllBytes($observedPath,$firstVisible)
        Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 $observedPath) 'first observable final leaf already has the sealed digest'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Split-Path $final -Parent) -File -Filter '.ccod.*.tmp').Count 'successful publication leaves no private temporary name'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'early source verification failure publishes no final leaf and close releases every stream' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-early-copy-failure';$source=New-CcodSourceFile $fixture 'bad-source.bin' 'source-owned-before-hash';$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$wrong=('0'*64)
        if($wrong-ceq$source.Sha256){$wrong='1'*64}
        Assert-CcodThrows {Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $wrong|Out-Null} 'CCOD_INSTALL_SOURCE_MISMATCH'
        $generationPath=Join-Path $fixture.Install "runtime\$runtimeId";Assert-CcodTrue (-not[IO.File]::Exists((Join-Path $generationPath 'payload.bin'))) 'source verification failure publishes no requested final leaf'
        Assert-CcodEqual 'blocked' (Invoke-CcodMoveAttempt $source.Path) 'early source stream is transaction-owned until close'
        Close-CcodInstallFileTransaction -Transaction $generation -Disposition Failed|Out-Null
        Assert-CcodEqual 'moved' (Invoke-CcodMoveAttempt $source.Path) 'Failed close releases the early source stream'
        $temporaries=@(Get-ChildItem -LiteralPath $generationPath -File -Filter '.ccod.*.tmp');foreach($temporary in $temporaries){Assert-CcodEqual 'moved' (Invoke-CcodMoveAttempt $temporary.FullName) 'Failed close releases every private temporary handle'}
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'source and destination handles remain private pinned and same-handle verified' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-pinned-copy';$source=New-CcodSourceFile $fixture 'source.bin' ('sealed-source-v1'*65536);$replacement=New-CcodSourceFile $fixture 'replacement.bin' ('attacker-bytes'*65536);$generation=Open-CcodFixtureGeneration $fixture $runtimeId
        $destination=Join-Path $fixture.Install "runtime\$runtimeId\payload.bin";$attack=[CcodInstallHandoffAttack]::new($destination,$replacement.Path);Assert-CcodTrue ($attack.WaitReady(5000)) 'handoff attacker is running before destination creation'
        $copyFailure=$null;$copy=$null
        try{$copy=Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256}catch{$copyFailure=$_}
        $attackOutcome=$attack.Stop();$attack.Dispose()
        Assert-CcodTrue ($attackOutcome-in@('blocked','exchanged')) 'handoff attacker completes with a bounded result'
        Assert-CcodTrue ($null-eq$copyFailure) "final-name attacker cannot cause a post-commit failure error=$($copyFailure.FullyQualifiedErrorId)"
        Assert-CcodEqual $source.Length $copy.Length 'copy returns verified length';Assert-CcodEqual $source.Sha256 $copy.Sha256 'copy returns verified digest'
        Assert-CcodEqual 'blocked' (Invoke-CcodMoveAttempt $source.Path) 'source replacement is blocked after its handle opens'
        $currentModule = Get-Module InstallFileTransaction
        $sealedPin = & $currentModule {
            param($Generation)
            $scope = Get-CcodInstallTransaction $Generation
            $pins = $scope.State.Runtime.GetType().GetField('pins',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($scope.State.Runtime)
            $flags = [Reflection.BindingFlags]'NonPublic,Instance'
            $pin = $null
            foreach ($candidate in $pins.Values) {
                $type = $candidate.GetType()
                if (-not [bool]$type.GetField('Directory',$flags).GetValue($candidate) -and [string]$type.GetField('Leaf',$flags).GetValue($candidate) -ceq 'payload.bin') { $pin = $candidate; break }
            }
            $pinType = $pin.GetType()
            $stream = $pinType.GetField('Stream',$flags).GetValue($pin)
            return [pscustomobject]@{StreamOpen=($null-ne$stream);Length=[int64]($pinType.GetField('SealedLength',$flags).GetValue($pin));Sha256=[string]($pinType.GetField('SealedSha',$flags).GetValue($pin));Published=[bool]($pinType.GetField('Published',$flags).GetValue($pin))}
        } $generation
        Assert-CcodTrue $sealedPin.Published 'handoff marks the pin published only after final rename'
        Assert-CcodTrue (-not $sealedPin.StreamOpen) 'post-commit path performs no potentially failing stream handoff'
        Assert-CcodEqual $source.Length $sealedPin.Length 'strict handoff pin retains the same-handle verified length'
        Assert-CcodEqual $source.Sha256 $sealedPin.Sha256 'strict handoff pin retains the same-handle verified digest'
        $visibleSha=Get-CcodTestFileSha256 $destination
        if($visibleSha-cne$source.Sha256){
            Write-CcodInstallGenerationManifest -Generation $generation -Manifest (New-CcodGenerationManifest $runtimeId)|Out-Null
            try{Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]0) -NewRuntimeId $runtimeId -FileTransaction $generation|Out-Null;throw 'ASSERT_ATTACKED_GENERATION_COMMITTED'}catch{Assert-CcodTrue ($_.FullyQualifiedErrorId-match'^CCOD_INSTALL_(?:PIN_CHANGED|SEAL_MISMATCH|UNKNOWN_LEAF)') 'post-commit same-user mutation cannot become an eligible generation'}
            return
        }
        Assert-CcodEqual $source.Sha256 $visibleSha 'successful sealed leaf is readable by path before transaction close'
        try {[IO.File]::WriteAllText($destination,'attacker');throw 'ASSERT_DESTINATION_MUTABLE'} catch [IO.IOException] {} catch [UnauthorizedAccessException] {}
        Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 $destination) 'published destination protection preserves verified bytes'
        Assert-CcodOutsideUnchanged $fixture 'pinned copy'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'manifest is create-only pinned and immutable after its same-handle write' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-manifest';$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$result=Write-CcodInstallGenerationManifest -Generation $generation -Manifest (New-CcodGenerationManifest $runtimeId)
        Assert-CcodTrue ($result.Length-gt 0) 'manifest returns verified length';Assert-CcodTrue ($result.Sha256-cmatch'^[0-9a-f]{64}$') 'manifest returns lowercase digest'
        $path=Join-Path $fixture.Install "runtime\$runtimeId\manifest.json";$before=Get-CcodTestFileSha256 $path
        Assert-CcodThrows {Write-CcodInstallGenerationManifest -Generation $generation -Manifest (New-CcodGenerationManifest $runtimeId)|Out-Null} 'CCOD_INSTALL_LEAF_EXISTS'
        try {[IO.File]::WriteAllText($path,'{"attacker":true}');throw 'ASSERT_MANIFEST_MUTABLE'} catch [IO.IOException] {} catch [UnauthorizedAccessException] {}
        Assert-CcodEqual $before (Get-CcodTestFileSha256 $path) 'manifest mutation changes no bytes';Assert-CcodOutsideUnchanged $fixture 'manifest immutability'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'rejects reparse ADS and multilink inputs before publishing a leaf' {
    foreach($case in @('reparse','ads','multilink')){
        $fixture=New-CcodInstallFileFixture
        try {
            $runtimeId="runtime-invalid-$case"
            if($case-ceq'reparse'){
                [IO.Directory]::CreateDirectory((Join-Path $fixture.Install 'runtime'))|Out-Null;New-CcodJunction (Join-Path $fixture.Install "runtime\$runtimeId") $fixture.Outside
                Assert-CcodThrows {Open-CcodInstallGeneration -InstallRoot $fixture.Install -RuntimeId $runtimeId|Out-Null} 'CCOD_INSTALL_GENERATION_EXISTS';Assert-CcodOutsideUnchanged $fixture 'reparse collision';continue
            }
            $source=New-CcodSourceFile $fixture 'source.bin' 'invalid-source';$generation=Open-CcodFixtureGeneration $fixture $runtimeId
            if($case-ceq'ads'){
                $previous=$ErrorActionPreference
                try {$ErrorActionPreference='Continue';$output=& cmd.exe /d /c "echo attacker>`"$($source.Path):metadata`"" 2>&1;$exitCode=$LASTEXITCODE} finally {$ErrorActionPreference=$previous}
                if($exitCode-ne 0){throw "Could not create alternate data stream: $($output -join ' ')"}
                $expected='CCOD_INSTALL_ADS_LEAF'
            }else{New-CcodHardLink (Join-Path $fixture.Outside 'outside-hardlink.bin') $source.Path;$expected='CCOD_INSTALL_MULTILINK_LEAF'}
            Assert-CcodThrows {Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null} $expected
            Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $fixture.Install "runtime\$runtimeId\payload.bin"))) "$case publishes no destination";Assert-CcodOutsideUnchanged $fixture "$case input"
        } finally {Remove-CcodInstallFileFixture $fixture}
    }
}

Invoke-CcodTest 'rejects forged cross-transaction and closed capabilities' {
    $firstFixture=New-CcodInstallFileFixture;$secondFixture=New-CcodInstallFileFixture
    try {
        $first=Open-CcodFixtureGeneration $firstFixture 'runtime-first';$second=Open-CcodFixtureGeneration $secondFixture 'runtime-second';$forged=New-Object psobject
        Assert-CcodThrows {New-CcodInstallGenerationLeaf -Generation $forged -Leaf 'forged'|Out-Null} 'CCOD_INSTALL_GENERATION_INVALID'
        Write-CcodInstallGenerationManifest -Generation $first -Manifest (New-CcodGenerationManifest 'runtime-first')|Out-Null
        Assert-CcodThrows {Commit-CcodInstallActivePointer -InstallRoot $secondFixture.Install -ExpectedPreviousGeneration ([uint64]0) -NewRuntimeId 'runtime-first' -FileTransaction $first|Out-Null} 'CCOD_INSTALL_TRANSACTION_SCOPE'
        Assert-CcodThrows {Retire-CcodInstallGeneration -InstallRoot $firstFixture.Install -RuntimeId 'runtime-first' -FileTransaction $second|Out-Null} 'CCOD_INSTALL_TRANSACTION_SCOPE'
        Close-CcodInstallFileTransaction -Transaction $first -Disposition Failed|Out-Null
        Assert-CcodThrows {New-CcodInstallGenerationLeaf -Generation $first -Leaf 'after-close'|Out-Null} 'CCOD_INSTALL_TRANSACTION_CLOSED'
        Assert-CcodOutsideUnchanged $firstFixture 'capability first';Assert-CcodOutsideUnchanged $secondFixture 'capability second'
    } finally {Remove-CcodInstallFileFixture $firstFixture;Remove-CcodInstallFileFixture $secondFixture}
}

Invoke-CcodTest 'close serializes native handle release against later relative operations' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-close-barrier';$source=New-CcodSourceFile $fixture 'close-source.bin' 'close-source';$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$child=New-CcodInstallGenerationLeaf -Generation $generation -Leaf 'child';Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null
        $currentModule=Get-Module InstallFileTransaction;$native=&$currentModule {param($Generation)$scope=Get-CcodInstallTransaction $Generation;[pscustomobject]@{Runtime=$scope.State.Runtime;Token=$scope.Record.Token}} $generation
        $race=[CcodInstallFileRaceProbe]::RaceCreateAndClose($native.Runtime,$native.Token,'racing-child');Assert-CcodTrue ($race-in@('created|closed','closed|closed')) "relative create and close serialize without native handle misuse actual=$race"
        Close-CcodInstallFileTransaction -Transaction $generation -Disposition Failed|Out-Null
        Assert-CcodThrows {New-CcodInstallGenerationLeaf -Generation $child -Leaf 'late'|Out-Null} 'CCOD_INSTALL_TRANSACTION_CLOSED'
        Assert-CcodEqual 'moved' (Invoke-CcodMoveAttempt $source.Path) 'close releases the deliberately retained source handle'
        $live=Join-Path $fixture.Install "runtime\$runtimeId";$moved=$live+'.moved';[IO.Directory]::Move($live,$moved);Assert-CcodTrue ([IO.Directory]::Exists($moved)) 'close releases generation and destination handles';Assert-CcodOutsideUnchanged $fixture 'close barrier'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'pointer generation records are monotonic create-only and collision safe' {
    $fixture=New-CcodInstallFileFixture
    try {
        $first=Open-CcodFixtureGeneration $fixture 'runtime-pointer-one';Write-CcodInstallGenerationManifest -Generation $first -Manifest (New-CcodGenerationManifest 'runtime-pointer-one')|Out-Null
        $committed=Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]0) -NewRuntimeId 'runtime-pointer-one' -FileTransaction $first
        Assert-CcodEqual ([uint64]1) ([uint64]$committed.Generation) 'first pointer generation is one'
        $records=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Filter '*.json');Assert-CcodEqual 1 $records.Count 'one pointer record';$before=Get-CcodTestFileSha256 $records[0].FullName
        $second=Open-CcodFixtureGeneration $fixture 'runtime-pointer-two';Write-CcodInstallGenerationManifest -Generation $second -Manifest (New-CcodGenerationManifest 'runtime-pointer-two')|Out-Null
        $secondCommit=Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]1) -NewRuntimeId 'runtime-pointer-two' -FileTransaction $second
        Assert-CcodEqual ([uint64]2) ([uint64]$secondCommit.Generation) 'second pointer generation increments to two'
        $after=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Filter '*.json'|Sort-Object Name);Assert-CcodEqual 2 $after.Count 'successful second commit appends one record';Assert-CcodEqual $before (Get-CcodTestFileSha256 $after[0].FullName) 'generation one remains unchanged'
        $third=Open-CcodFixtureGeneration $fixture 'runtime-pointer-three';Write-CcodInstallGenerationManifest -Generation $third -Manifest (New-CcodGenerationManifest 'runtime-pointer-three')|Out-Null
        Assert-CcodThrows {Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]1) -NewRuntimeId 'runtime-pointer-three' -FileTransaction $third|Out-Null} 'CCOD_INSTALL_POINTER_GENERATION_EXISTS'
        Assert-CcodEqual 2 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Filter '*.json').Count 'no-replace contender publishes no third record'
        Assert-CcodThrows {Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]::MaxValue) -NewRuntimeId 'runtime-pointer-three' -FileTransaction $third|Out-Null} 'CCOD_INSTALL_POINTER_GENERATION_OVERFLOW'
        Assert-CcodEqual 2 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Filter '*.json').Count 'overflow publishes no record'
        Assert-CcodOutsideUnchanged $fixture 'pointer monotonicity'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'independent transactions race one pointer generation with exactly one no-replace winner' {
    $fixture=New-CcodInstallFileFixture
    $processes=@()
    try {
        $initial=Open-CcodFixtureGeneration $fixture 'runtime-pointer-initial';Write-CcodInstallGenerationManifest -Generation $initial -Manifest (New-CcodGenerationManifest 'runtime-pointer-initial')|Out-Null
        Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]0) -NewRuntimeId 'runtime-pointer-initial' -FileTransaction $initial|Out-Null
        $go=Join-Path $fixture.Base 'go';$escapedModule=$modulePath.Replace("'","''");$escapedRoot=$fixture.Install.Replace("'","''")
        foreach($index in 1..2){
            $runtimeId="runtime-pointer-racer-$index";$scriptPath=Join-Path $fixture.Base "racer-$index.ps1";$ready=Join-Path $fixture.Base "ready-$index";$outcome=Join-Path $fixture.Base "outcome-$index"
            $scriptText=@"
`$ErrorActionPreference='Stop'
Import-Module '$escapedModule' -Force -DisableNameChecking
`$tx=`$null
try {
    `$tx=Open-CcodInstallGeneration -InstallRoot '$escapedRoot' -RuntimeId '$runtimeId'
    `$manifest=[ordered]@{schemaVersion=1;projectVersion='2.5.22';runtimeId='$runtimeId';commit='0123456789abcdef0123456789abcdef01234567';files=@()}
    Write-CcodInstallGenerationManifest -Generation `$tx -Manifest `$manifest|Out-Null
    [IO.File]::WriteAllText('$($ready.Replace("'","''"))','ready')
    `$deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(-not[IO.File]::Exists('$($go.Replace("'","''"))')){if([DateTime]::UtcNow-gt`$deadline){throw 'barrier timeout'};Start-Sleep -Milliseconds 10}
    try{Commit-CcodInstallActivePointer -InstallRoot '$escapedRoot' -ExpectedPreviousGeneration ([uint64]1) -NewRuntimeId '$runtimeId' -FileTransaction `$tx|Out-Null;[IO.File]::WriteAllText('$($outcome.Replace("'","''"))','success')}
    catch{[IO.File]::WriteAllText('$($outcome.Replace("'","''"))',[string]`$_.FullyQualifiedErrorId)}
} finally {if(`$null-ne`$tx){Close-CcodInstallFileTransaction -Transaction `$tx -Disposition Failed|Out-Null}}
"@
            [IO.File]::WriteAllText($scriptPath,$scriptText)
            $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $processes+=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) -WindowStyle Hidden -PassThru
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while(@(1..2|Where-Object{-not[IO.File]::Exists((Join-Path $fixture.Base "ready-$_"))}).Count-ne 0){if([DateTime]::UtcNow-gt$deadline){throw 'pointer racers did not reach the barrier'};Start-Sleep -Milliseconds 20}
        [IO.File]::WriteAllText($go,'go')
        foreach($process in $processes){if(-not$process.WaitForExit(20000)){Stop-Process -Id $process.Id -Force;throw 'pointer racer timed out'};Assert-CcodEqual 0 $process.ExitCode 'pointer racer handles its no-replace result'}
        $outcomes=@(1..2|ForEach-Object{[IO.File]::ReadAllText((Join-Path $fixture.Base "outcome-$_"))})
        Assert-CcodEqual 1 @($outcomes|Where-Object{$_-ceq'success'}).Count 'exactly one pointer racer wins'
        Assert-CcodEqual 1 @($outcomes|Where-Object{$_-like'CCOD_INSTALL_POINTER_GENERATION_EXISTS*'}).Count 'losing pointer racer gets the stable collision code'
        Assert-CcodEqual 2 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Filter '*.json').Count 'race appends exactly one generation-two record'
    } finally {
        foreach($process in $processes){if(-not$process.HasExited){Stop-Process -Id $process.Id -Force}}
        Remove-CcodInstallFileFixture $fixture
    }
}

Invoke-CcodTest 'retirement writes one create-only record and keeps the nonempty generation in place' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-retire';$source=New-CcodSourceFile $fixture 'source.bin' 'retained-retirement-bytes';$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$child=New-CcodInstallGenerationLeaf $generation 'child'
        Copy-CcodInstallSealedSource -Generation $child -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null
        Write-CcodInstallGenerationManifest -Generation $generation -Manifest (New-CcodGenerationManifest $runtimeId @([ordered]@{path='child\payload.bin';length=$source.Length;sha256=$source.Sha256}))|Out-Null
        $live=Join-Path $fixture.Install "runtime\$runtimeId";$beforeSddl=(Get-Acl -LiteralPath $live).Sddl;$retirement=Retire-CcodInstallGeneration -InstallRoot $fixture.Install -RuntimeId $runtimeId -FileTransaction $generation
        Assert-CcodEqual 'Retired' $retirement.Disposition 'bounded retirement result';Assert-CcodEqual '' (@($retirement.Capability.PSObject.Properties.Name)-join ',') 'retirement capability opaque';Assert-CcodTrue ([IO.Directory]::Exists($live)) 'record-only retirement keeps the generation live name in place'
        Assert-CcodThrows {Copy-CcodInstallSealedSource -Generation $retirement.Capability -SourcePath $source.Path -Leaf 'post-retire.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null} 'CCOD_INSTALL_GENERATION_RETIRED'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $live 'post-retire.bin'))) 'retired capability cannot mutate retained generation bytes'
        Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 (Join-Path $live 'child\payload.bin')) 'retained generation bytes remain readable and unchanged';Assert-CcodEqual $beforeSddl (Get-Acl -LiteralPath $live).Sddl 'retirement changes no DACL'
        $records=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\retired-generations') -File -Filter '*.json');Assert-CcodEqual 1 $records.Count 'one retirement record'
        $repeated=Retire-CcodInstallGeneration -InstallRoot $fixture.Install -RuntimeId $runtimeId -FileTransaction $generation
        Assert-CcodEqual 'Retired' $repeated.Disposition 'repeated retirement is idempotent';Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\retired-generations') -File -Filter '*.json').Count 'idempotent retirement writes no second record'
        Assert-CcodOutsideUnchanged $fixture 'record-only retirement'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'retirement collision and record I/O failure leave generation eligible and mutable' {
    foreach($case in @('collision','io-failure')){
        $fixture=New-CcodInstallFileFixture
        try {
            $runtimeId="runtime-retire-$case";$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$state=Join-Path $fixture.Install 'state';[IO.Directory]::CreateDirectory($state)|Out-Null
            if($case-ceq'collision'){
                $records=Join-Path $state 'retired-generations';[IO.Directory]::CreateDirectory($records)|Out-Null;$record=Join-Path $records ($runtimeId+'.json');[IO.File]::WriteAllText($record,'attacker-record');$recordSha=Get-CcodTestFileSha256 $record;$expected='CCOD_INSTALL_RETIREMENT_RECORD_EXISTS'
            }else{
                [IO.File]::WriteAllText((Join-Path $state 'retired-generations'),'not-a-directory');$expected='CCOD_INSTALL_RETIREMENT_FAILED'
            }
            Assert-CcodThrows {Retire-CcodInstallGeneration -InstallRoot $fixture.Install -RuntimeId $runtimeId -FileTransaction $generation|Out-Null} $expected
            $child=New-CcodInstallGenerationLeaf -Generation $generation -Leaf 'still-mutable';Assert-CcodEqual '' (@($child.PSObject.Properties.Name)-join ',') "$case retains the original capability"
            Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $fixture.Install "runtime\$runtimeId\still-mutable"))) "$case keeps the generation in place"
            if($case-ceq'collision'){
                Assert-CcodEqual $recordSha (Get-CcodTestFileSha256 $record) 'retirement collision preserves the existing record'
                $temporary=@(Get-ChildItem -LiteralPath $records -File -Filter '.ccod.*.tmp');Assert-CcodEqual 1 $temporary.Count 'failed no-replace retirement deliberately retains one diagnostic temporary record'
                Assert-CcodEqual 'moved' (Invoke-CcodMoveAttempt $temporary[0].FullName) 'failed no-replace rename leaves no temporary stream locked'
                Close-CcodInstallFileTransaction -Transaction $generation -Disposition Failed|Out-Null
                [IO.File]::SetAttributes($temporary[0].FullName+'.moved',[IO.FileAttributes]::Normal);[IO.File]::Delete($temporary[0].FullName+'.moved');Assert-CcodTrue (-not[IO.File]::Exists($temporary[0].FullName+'.moved')) 'Failed disposition leaves the released diagnostic temporary removable'
            }
        } finally {Remove-CcodInstallFileFixture $fixture}
    }
}

Write-Host 'Install file transaction self-test passed.' -ForegroundColor Green
