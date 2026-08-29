$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $projectRoot 'src\persistence\modules\InstallFileTransaction.psm1'
$module = Import-Module $modulePath -Force -PassThru -DisableNameChecking

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
    Assert-CcodEqual 1 ([CcodInstallCapabilityMarker]::CapabilityAbi) 'marker exposes a non-mutating ABI value'
    Assert-CcodEqual 'CcodInstallCapabilityMarker' ((@([CcodInstallCapabilityMarker].Assembly.GetExportedTypes()|ForEach-Object FullName)) -join '|') 'CLR bridge exports only the inert marker'
    $dangerous=@([CcodInstallCapabilityMarker].GetMethods([Reflection.BindingFlags]'Public,Static,DeclaredOnly')|Where-Object{@($_.GetParameters()|Where-Object{$_.ParameterType-in@([string],[IntPtr],[IO.Stream])-or[Microsoft.Win32.SafeHandles.SafeHandle].IsAssignableFrom($_.ParameterType)}).Count-ne 0})
    Assert-CcodEqual 0 $dangerous.Count 'marker accepts no path stream or bare handle'
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

Invoke-CcodTest 'source and destination handles remain private pinned and same-handle verified' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-pinned-copy';$source=New-CcodSourceFile $fixture 'source.bin' 'sealed-source-v1';$generation=Open-CcodFixtureGeneration $fixture $runtimeId
        $copy=Copy-CcodInstallSealedSource -Generation $generation -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256
        Assert-CcodEqual $source.Length $copy.Length 'copy returns verified length';Assert-CcodEqual $source.Sha256 $copy.Sha256 'copy returns verified digest'
        Assert-CcodEqual 'blocked' (Invoke-CcodMoveAttempt $source.Path) 'source replacement is blocked after its handle opens'
        $destination=Join-Path $fixture.Install "runtime\$runtimeId\payload.bin";Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 $destination) 'destination bytes match sealed handle digest'
        try {[IO.File]::WriteAllText($destination,'attacker');throw 'ASSERT_DESTINATION_MUTABLE'} catch [IO.IOException] {}
        Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 $destination) 'destination handle blocks mutation after verification'
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
        try {[IO.File]::WriteAllText($path,'{"attacker":true}');throw 'ASSERT_MANIFEST_MUTABLE'} catch [IO.IOException] {}
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
        $runtimeId='runtime-close-barrier';$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$child=New-CcodInstallGenerationLeaf -Generation $generation -Leaf 'child'
        Close-CcodInstallFileTransaction -Transaction $generation -Disposition Failed|Out-Null
        Assert-CcodThrows {New-CcodInstallGenerationLeaf -Generation $child -Leaf 'late'|Out-Null} 'CCOD_INSTALL_TRANSACTION_CLOSED'
        $live=Join-Path $fixture.Install "runtime\$runtimeId";$moved=$live+'.moved';[IO.Directory]::Move($live,$moved);Assert-CcodTrue ([IO.Directory]::Exists($moved)) 'close released native handles';Assert-CcodOutsideUnchanged $fixture 'close barrier'
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
        Assert-CcodThrows {Commit-CcodInstallActivePointer -InstallRoot $fixture.Install -ExpectedPreviousGeneration ([uint64]0) -NewRuntimeId 'runtime-pointer-two' -FileTransaction $second|Out-Null} 'CCOD_INSTALL_POINTER_GENERATION_EXISTS'
        $after=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Filter '*.json');Assert-CcodEqual 1 $after.Count 'duplicate publishes no record';Assert-CcodEqual $before (Get-CcodTestFileSha256 $after[0].FullName) 'existing pointer unchanged';Assert-CcodOutsideUnchanged $fixture 'pointer collision'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Invoke-CcodTest 'atomically retires a proven nonempty generation without deleting bytes or changing its DACL' {
    $fixture=New-CcodInstallFileFixture
    try {
        $runtimeId='runtime-retire';$source=New-CcodSourceFile $fixture 'source.bin' 'retained-retirement-bytes';$generation=Open-CcodFixtureGeneration $fixture $runtimeId;$child=New-CcodInstallGenerationLeaf $generation 'child'
        Copy-CcodInstallSealedSource -Generation $child -SourcePath $source.Path -Leaf 'payload.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null
        Write-CcodInstallGenerationManifest -Generation $generation -Manifest (New-CcodGenerationManifest $runtimeId @([ordered]@{path='child\payload.bin';length=$source.Length;sha256=$source.Sha256}))|Out-Null
        $live=Join-Path $fixture.Install "runtime\$runtimeId";$beforeSddl=(Get-Acl -LiteralPath $live).Sddl;$retirement=Retire-CcodInstallGeneration -InstallRoot $fixture.Install -RuntimeId $runtimeId -FileTransaction $generation
        Assert-CcodEqual 'Retired' $retirement.Disposition 'bounded retirement result';Assert-CcodEqual '' (@($retirement.Capability.PSObject.Properties.Name)-join ',') 'retirement capability opaque';Assert-CcodTrue (-not [IO.Directory]::Exists($live)) 'live name disappears'
        $retired=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'retired') -Directory|Where-Object Name -Like "$runtimeId.*");Assert-CcodEqual 1 $retired.Count 'one quarantine generation';Assert-CcodTrue ($retired[0].Name-cmatch('^'+[regex]::Escape($runtimeId)+'\.[0-9a-f]{32}$')) 'unique owned suffix'
        Assert-CcodThrows {Copy-CcodInstallSealedSource -Generation $retirement.Capability -SourcePath $source.Path -Leaf 'post-retire.bin' -ExpectedLength $source.Length -ExpectedSha256 $source.Sha256|Out-Null} 'CCOD_INSTALL_GENERATION_RETIRED'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $retired[0].FullName 'post-retire.bin'))) 'retired capability cannot mutate quarantine bytes'
        Assert-CcodEqual $source.Sha256 (Get-CcodTestFileSha256 (Join-Path $retired[0].FullName 'child\payload.bin')) 'retired bytes unchanged';Assert-CcodEqual $beforeSddl (Get-Acl -LiteralPath $retired[0].FullName).Sddl 'no persistent DACL mutation'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\retirements') -File -Filter '*.json').Count 'one retirement record';Assert-CcodOutsideUnchanged $fixture 'retirement'
    } finally {Remove-CcodInstallFileFixture $fixture}
}

Write-Host 'Install file transaction self-test passed.' -ForegroundColor Green
