$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\UiActions.psm1'
if(-not [IO.File]::Exists($modulePath)){throw 'MISSING_UI_ACTIONS_MODULE: src\persistence\modules\UiActions.psm1'}

Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force
Import-Module $modulePath -Force

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ccod ui actions '+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$powershellPath=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))

function New-CcodUiActionFixture {
    param([string]$Name,[bool]$IncludeUninstaller=$true)
    $installRoot=Join-Path $testRoot $Name
    $staging=Join-Path $installRoot 'runtime\staging'
    [IO.Directory]::CreateDirectory($staging)|Out-Null
    if($IncludeUninstaller){
        [IO.File]::WriteAllText((Join-Path $staging 'Uninstall-CodexControlOtherDevices.ps1'),'param() # trusted runtime uninstaller',[Text.UTF8Encoding]::new($false))
    }else{
        [IO.File]::WriteAllText((Join-Path $staging 'other.ps1'),'param() # not the uninstaller',[Text.UTF8Encoding]::new($false))
    }
    $manifest=New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion '7.0.0'
    $runtimeRoot=Join-Path (Join-Path $installRoot 'runtime') $manifest.runtimeId
    [IO.Directory]::Move($staging,$runtimeRoot)
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'manifest.json'),($manifest|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'active.json'),(([ordered]@{
        schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[UInt64]1;updatedAtUtc='2030-02-03T04:05:06.0000000Z'
    }|ConvertTo-Json -Depth 8)),[Text.UTF8Encoding]::new($false))
    [pscustomobject][ordered]@{
        InstallRoot=[IO.Path]::GetFullPath($installRoot)
        RuntimeRoot=[IO.Path]::GetFullPath($runtimeRoot)
        RuntimeId=$manifest.runtimeId
        RuntimeUninstaller=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'Uninstall-CodexControlOtherDevices.ps1'))
        Manifest=$manifest
    }
}

function New-CcodUiActionFakeAdapters {
    param($Calls)
    @{
        ReadActiveRuntime={param($InstallRoot)Read-CcodActiveRuntime -InstallRoot $InstallRoot}
        ValidateRuntimeManifest={param($RuntimeRoot,$ExpectedRuntimeId)Test-CcodRuntimeManifest -RuntimeDirectory $RuntimeRoot -ExpectedRuntimeId $ExpectedRuntimeId}
        GetItem={param($Path)Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop}
        StartProcess={
            param($FilePath,[string[]]$Arguments)
            $Calls.Start++
            $Calls.FilePath=$FilePath
            $Calls.Arguments=[string[]]@($Arguments)
            [pscustomobject][ordered]@{Pid=[int]4242;CreationTimeUtc='2030-02-03T04:05:07.0000000Z'}
        }.GetNewClosure()
    }
}

function New-CcodUiActionCalls {
    [pscustomobject][ordered]@{Start=0;FilePath=$null;Arguments=$null}
}

$results=[Collections.Generic.List[object]]::new()
try{
    $results.Add((Invoke-CcodTest 'exports only the safe tray uninstall launcher and keeps exactly four adapter names' {
        Assert-CcodEqual 'Start-CcodTrayUninstall' (((Get-Command -Module UiActions -CommandType Function).Name|Sort-Object)-join ',') 'public export is exact'
        $names=& (Get-Module UiActions) {@((Get-CcodUiActionAdapters $null).Keys|Sort-Object)}
        Assert-CcodEqual 'GetItem,ReadActiveRuntime,StartProcess,ValidateRuntimeManifest' ($names-join ',') 'adapter names are exact'
    }))

    $results.Add((Invoke-CcodTest 'quotes each Windows argument independently with hand-derived literals and builds a hidden non-shell start' {
        $module=Get-Module UiActions
        $cases=@(
            [pscustomobject]@{Input='';Expected='""'},
            [pscustomobject]@{Input='C:\Program Files\Codex\tool.ps1';Expected='"C:\Program Files\Codex\tool.ps1"'},
            [pscustomobject]@{Input='value"quoted';Expected='"value\"quoted"'},
            [pscustomobject]@{Input='C:\A B\';Expected='"C:\A B\\"'}
        )
        foreach($case in $cases){
            $actual=& $module {param($Value)ConvertTo-CcodUiActionArgument -Argument $Value} $case.Input
            Assert-CcodEqual $case.Expected $actual "quotes $($case.Input)"
        }
        $info=& $module {New-CcodUiActionStartInfo -FilePath 'C:\Windows\powershell.exe' -Arguments ([string[]]@('one two','three'))}
        Assert-CcodEqual 'C:\Windows\powershell.exe' $info.FileName 'approved host is the process file'
        Assert-CcodEqual '"one two" "three"' $info.Arguments 'only individually quoted vector elements are joined'
        Assert-CcodEqual $false $info.UseShellExecute 'shell execution is disabled'
        Assert-CcodEqual $true $info.CreateNoWindow 'console creation is disabled'
        Assert-CcodEqual 'Hidden' ([string]$info.WindowStyle) 'window style is hidden'
    }))

    $results.Add((Invoke-CcodTest 'launches only the manifest-bound active runtime uninstaller with the exact eight-element vector' {
        $fixture=New-CcodUiActionFixture 'valid runtime'
        $calls=New-CcodUiActionCalls
        $adapters=New-CcodUiActionFakeAdapters $calls
        $equivalentRuntime=Join-Path $fixture.RuntimeRoot '.'
        $receipt=Start-CcodTrayUninstall -InstallRoot $fixture.InstallRoot -RuntimeRoot $equivalentRuntime -PowerShellPath $powershellPath -Adapters $adapters
        Assert-CcodEqual 'Started,Pid,CreationTimeUtc' (($receipt.PSObject.Properties.Name)-join ',') 'exact receipt'
        Assert-CcodEqual $true $receipt.Started 'receipt confirms start'
        Assert-CcodEqual 4242 $receipt.Pid 'receipt preserves exact pid'
        Assert-CcodEqual '2030-02-03T04:05:07.0000000Z' $receipt.CreationTimeUtc 'receipt preserves canonical creation UTC'
        Assert-CcodEqual 1 $calls.Start 'one fake process starts'
        Assert-CcodEqual $powershellPath $calls.FilePath 'approved host executable'
        Assert-CcodEqual 8 $calls.Arguments.Count 'argument vector has no extras'
        Assert-CcodEqual '-NoProfile' $calls.Arguments[0] 'profile disabled'
        Assert-CcodEqual '-ExecutionPolicy' $calls.Arguments[1] 'policy switch'
        Assert-CcodEqual 'Bypass' $calls.Arguments[2] 'policy value'
        Assert-CcodEqual '-File' $calls.Arguments[3] 'script switch'
        Assert-CcodEqual $fixture.RuntimeUninstaller $calls.Arguments[4] 'manifest-bound uninstaller'
        Assert-CcodEqual '-InstallRoot' $calls.Arguments[5] 'root switch'
        Assert-CcodEqual $fixture.InstallRoot $calls.Arguments[6] 'exact install root'
        Assert-CcodEqual '-Confirm:$false' $calls.Arguments[7] 'second prompt suppressed after tray confirmation'
    }))

    $results.Add((Invoke-CcodTest 'does not confuse distinct literal manifest property prefixes with duplicates' {
        $fixture=New-CcodUiActionFixture 'distinct property prefix'
        $record=@($fixture.Manifest.files|Where-Object{$_.path -ceq 'Uninstall-CodexControlOtherDevices.ps1'})[0]
        $manifestJson=@"
{
  "schemaVersion": 1,
  "projectVersion": "7.0.0",
  "runtimeId": "$($fixture.RuntimeId)",
  "files": [
    {
      "path": "Uninstall-CodexControlOtherDevices.ps1",
      "pathSuffix": "not-the-same-property",
      "length": $($record.length),
      "sha256": "$($record.sha256)"
    }
  ]
}
"@
        [IO.File]::WriteAllText((Join-Path $fixture.RuntimeRoot 'manifest.json'),$manifestJson,[Text.UTF8Encoding]::new($false))
        $calls=New-CcodUiActionCalls
        $receipt=Start-CcodTrayUninstall -InstallRoot $fixture.InstallRoot -RuntimeRoot $fixture.RuntimeRoot -PowerShellPath $powershellPath -Adapters (New-CcodUiActionFakeAdapters $calls)
        Assert-CcodEqual $true $receipt.Started 'distinct property prefixes preserve the validated launch result'
        Assert-CcodEqual 1 $calls.Start 'distinct property prefixes reach only the fake process boundary'
    }))

    $results.Add((Invoke-CcodTest 'accepts literal string values containing braces and escaped quotes' {
        $fixture=New-CcodUiActionFixture 'literal string lexical state'
        $record=@($fixture.Manifest.files|Where-Object{$_.path -ceq 'Uninstall-CodexControlOtherDevices.ps1'})[0]
        $manifestJson=@"
{
  "schemaVersion": 1,
  "projectVersion": "7.0.0",
  "runtimeId": "$($fixture.RuntimeId)",
  "description": "literal { left } right and \"quoted\" text",
  "files": [
    { "path": "Uninstall-CodexControlOtherDevices.ps1", "length": $($record.length), "sha256": "$($record.sha256)" }
  ]
}
"@
        [IO.File]::WriteAllText((Join-Path $fixture.RuntimeRoot 'manifest.json'),$manifestJson,[Text.UTF8Encoding]::new($false))
        $calls=New-CcodUiActionCalls
        $receipt=Start-CcodTrayUninstall -InstallRoot $fixture.InstallRoot -RuntimeRoot $fixture.RuntimeRoot -PowerShellPath $powershellPath -Adapters (New-CcodUiActionFakeAdapters $calls)
        Assert-CcodEqual $true $receipt.Started 'braces and escaped quotes inside a value remain lexical data'
        Assert-CcodEqual 1 $calls.Start 'lexical string fixture reaches only the fake process boundary'
    }))

    $results.Add((Invoke-CcodTest 'rejects literal manifests with duplicate root or file properties before any process start' {
        foreach($variant in @('duplicate root property','duplicate file property','duplicate file property with prefix collision')){
            $fixture=New-CcodUiActionFixture $variant
            $record=@($fixture.Manifest.files|Where-Object{$_.path -ceq 'Uninstall-CodexControlOtherDevices.ps1'})[0]
            $manifestJson=switch($variant){
                'duplicate root property' {@"
{
  "schemaVersion": 1,
  "projectVersion": "7.0.0",
  "runtimeId": "$($fixture.RuntimeId)",
  "runtimeId": "$($fixture.RuntimeId)",
  "files": [
    { "path": "Uninstall-CodexControlOtherDevices.ps1", "length": $($record.length), "sha256": "$($record.sha256)" }
  ]
}
"@}
                'duplicate file property' {@"
{
  "schemaVersion": 1,
  "projectVersion": "7.0.0",
  "runtimeId": "$($fixture.RuntimeId)",
  "files": [
    {
      "path": "Uninstall-CodexControlOtherDevices.ps1",
      "path": "Uninstall-CodexControlOtherDevices.ps1",
      "length": $($record.length),
      "sha256": "$($record.sha256)"
    }
  ]
}
"@}
                'duplicate file property with prefix collision' {@"
{
  "schemaVersion": 1,
  "projectVersion": "7.0.0",
  "runtimeId": "$($fixture.RuntimeId)",
  "files": [
    {
      "path": "Uninstall-CodexControlOtherDevices.ps1",
      "pathSuffix": "not-the-same-property",
      "path": "Uninstall-CodexControlOtherDevices.ps1",
      "length": $($record.length),
      "sha256": "$($record.sha256)"
    }
  ]
}
"@}
            }
            [IO.File]::WriteAllText((Join-Path $fixture.RuntimeRoot 'manifest.json'),$manifestJson,[Text.UTF8Encoding]::new($false))
            $calls=New-CcodUiActionCalls
            $caught=$null
            try{
                Start-CcodTrayUninstall -InstallRoot $fixture.InstallRoot -RuntimeRoot $fixture.RuntimeRoot -PowerShellPath $powershellPath -Adapters (New-CcodUiActionFakeAdapters $calls)|Out-Null
            }catch{$caught=$_}
            Assert-CcodEqual 0 $calls.Start "$variant never reaches StartProcess"
            Assert-CcodTrue ($null -ne $caught) "$variant returns a stable rejection"
            Assert-CcodEqual 'CCOD_UNINSTALL_RUNTIME_INVALID' (([string]$caught.FullyQualifiedErrorId -split ',')[0]) "$variant uses the stable launcher rejection"
        }
    }))

    $results.Add((Invoke-CcodTest 'rejects missing manifest mismatch unhashed script reparse escape wrong host and extra adapters before launch' {
        $cases=[Collections.Generic.List[object]]::new()

        $missing=New-CcodUiActionFixture 'missing manifest'
        [IO.File]::Delete((Join-Path $missing.RuntimeRoot 'manifest.json'))
        $cases.Add([pscustomobject]@{Name='missing manifest';Fixture=$missing;ErrorId='CCOD_RUNTIME_MANIFEST_MISSING';Mutate={param($Adapters,$Fixture)}})

        $inactive=New-CcodUiActionFixture 'inactive runtime'
        $inactiveRoot=Join-Path (Join-Path $inactive.InstallRoot 'runtime') 'inactive-runtime'
        [IO.Directory]::CreateDirectory($inactiveRoot)|Out-Null
        $cases.Add([pscustomobject]@{Name='inactive runtime';Fixture=$inactive;RuntimeRoot=$inactiveRoot;ErrorId='CCOD_UNINSTALL_RUNTIME_MISMATCH';Mutate={param($Adapters,$Fixture)}})

        $unhashed=New-CcodUiActionFixture 'unhashed runtime' $false
        $cases.Add([pscustomobject]@{Name='unhashed uninstaller';Fixture=$unhashed;ErrorId='CCOD_UNINSTALL_SCRIPT_UNHASHED';Mutate={param($Adapters,$Fixture)}})

        $mismatch=New-CcodUiActionFixture 'manifest mismatch'
        [IO.File]::WriteAllText($mismatch.RuntimeUninstaller,'param() # altered runtime uninstall!!',[Text.UTF8Encoding]::new($false))
        $cases.Add([pscustomobject]@{Name='manifest mismatch';Fixture=$mismatch;ErrorId='CCOD_RUNTIME_FILE_HASH_MISMATCH';Mutate={param($Adapters,$Fixture)}})

        $reparse=New-CcodUiActionFixture 'reparse runtime'
        $cases.Add([pscustomobject]@{Name='reparse uninstaller';Fixture=$reparse;ErrorId='CCOD_REPARSE_PATH';Mutate={
            param($Adapters,$Fixture)
            $scriptPath=$Fixture.RuntimeUninstaller
            $Adapters.GetItem={
                param($Path)
                $item=Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                if([IO.Path]::GetFullPath($Path).Equals($scriptPath,[StringComparison]::OrdinalIgnoreCase)){
                    [pscustomobject]@{Attributes=($item.Attributes -bor [IO.FileAttributes]::ReparsePoint);PSIsContainer=$false;FullName=$item.FullName}
                }else{$item}
            }.GetNewClosure()
        }})

        $escape=New-CcodUiActionFixture 'escaped active runtime'
        $cases.Add([pscustomobject]@{Name='escaped active runtime';Fixture=$escape;ErrorId='CCOD_PATH_OUTSIDE_ROOT';Mutate={
            param($Adapters,$Fixture)
            $Adapters.ReadActiveRuntime={[pscustomobject]@{activeRuntime='..\..\outside'}}
        }})

        $manifestEscape=New-CcodUiActionFixture 'escaped manifest path'
        $record=$manifestEscape.Manifest.files[0]
        [IO.File]::WriteAllText((Join-Path $manifestEscape.RuntimeRoot 'manifest.json'),(([ordered]@{
            schemaVersion=1;projectVersion='7.0.0';runtimeId=$manifestEscape.RuntimeId
            files=@([ordered]@{path='../outside.ps1';length=$record.length;sha256=$record.sha256})
        }|ConvertTo-Json -Depth 8)),[Text.UTF8Encoding]::new($false))
        $cases.Add([pscustomobject]@{Name='escaped manifest path';Fixture=$manifestEscape;ErrorId='CCOD_PATH_OUTSIDE_ROOT';Mutate={param($Adapters,$Fixture)}})

        $wrongHost=New-CcodUiActionFixture 'wrong host'
        $cases.Add([pscustomobject]@{Name='wrong host';Fixture=$wrongHost;PowerShellPath=(Join-Path $wrongHost.InstallRoot 'powershell.exe');ErrorId='CCOD_UNINSTALL_HOST_INVALID';Mutate={param($Adapters,$Fixture)}})

        $extra=New-CcodUiActionFixture 'extra adapter'
        $cases.Add([pscustomobject]@{Name='extra adapter';Fixture=$extra;ErrorId='CCOD_UNINSTALL_ADAPTER_INVALID';Mutate={param($Adapters,$Fixture)$Adapters.ExtraArgument={}}})

        foreach($case in $cases){
            $calls=New-CcodUiActionCalls
            $adapters=New-CcodUiActionFakeAdapters $calls
            & $case.Mutate $adapters $case.Fixture
            $runtimeRoot=if($case.PSObject.Properties['RuntimeRoot']){$case.RuntimeRoot}else{$case.Fixture.RuntimeRoot}
            $selectedPowerShellPath=if($case.PSObject.Properties['PowerShellPath']){$case.PowerShellPath}else{$powershellPath}
            Assert-CcodThrows {Start-CcodTrayUninstall -InstallRoot $case.Fixture.InstallRoot -RuntimeRoot $runtimeRoot -PowerShellPath $selectedPowerShellPath -Adapters $adapters|Out-Null} $case.ErrorId
            Assert-CcodEqual 0 $calls.Start "$($case.Name) starts no process"
        }
    }))

    $results.Add((Invoke-CcodTest 'reduces malformed receipts and launch exceptions to stable IDs after one fake start attempt' {
        $fixture=New-CcodUiActionFixture 'launch failures'

        $malformedCalls=New-CcodUiActionCalls
        $malformed=New-CcodUiActionFakeAdapters $malformedCalls
        $malformed.StartProcess={param($FilePath,[string[]]$Arguments)$malformedCalls.Start++;[pscustomobject][ordered]@{Pid=4242;CreationTimeUtc='not-utc';Extra=$true}}.GetNewClosure()
        Assert-CcodThrows {Start-CcodTrayUninstall -InstallRoot $fixture.InstallRoot -RuntimeRoot $fixture.RuntimeRoot -PowerShellPath $powershellPath -Adapters $malformed|Out-Null} 'CCOD_UNINSTALL_PROCESS_RECEIPT_INVALID'
        Assert-CcodEqual 1 $malformedCalls.Start 'malformed receipt follows one fake start attempt'

        $failedCalls=New-CcodUiActionCalls
        $failed=New-CcodUiActionFakeAdapters $failedCalls
        $failed.StartProcess={param($FilePath,[string[]]$Arguments)$failedCalls.Start++;throw 'PRIVATE_LAUNCH_PATH_OR_TOKEN'}.GetNewClosure()
        Assert-CcodThrows {Start-CcodTrayUninstall -InstallRoot $fixture.InstallRoot -RuntimeRoot $fixture.RuntimeRoot -PowerShellPath $powershellPath -Adapters $failed|Out-Null} 'CCOD_UNINSTALL_START_FAILED'
        Assert-CcodEqual 1 $failedCalls.Start 'launch failure follows one fake start attempt'
    }))
}finally{
    if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$true)}
}

$results|ForEach-Object{"PASS $($_.Name)"}
Write-Output "UiActions self-tests passed: $($results.Count)"
