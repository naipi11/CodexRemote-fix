$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\ProcessControl.psm1') -Force

function New-CcodSnapshot {
    param(
        [int]$ProcessId = 100,
        [string]$CreationTimeUtc = '2026-08-02T00:00:00.0000000Z',
        [int]$SessionId = 1,
        [string]$UserSid = 'S-1-5-21-test',
        [string]$Path = 'C:\Codex\ChatGPT.exe',
        [string]$PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0',
        [string]$CommandLine = '"C:\Codex\ChatGPT.exe"',
        [AllowNull()][Nullable[int]]$ParentPid = $null,
        [bool]$IsTopLevel = $true,
        [ValidateSet('Ordinary', 'Special', 'Unrelated')][string]$Mode = 'Ordinary',
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null
    )

    [pscustomobject][ordered]@{
        Pid = $ProcessId
        CreationTimeUtc = $CreationTimeUtc
        SessionId = $SessionId
        UserSid = $UserSid
        Path = $Path
        PackageFamilyName = $PackageFamilyName
        CommandLine = $CommandLine
        ParentPid = $ParentPid
        IsTopLevel = $IsTopLevel
        Mode = $Mode
        RendererPort = $RendererPort
        MainPort = $MainPort
    }
}

function New-CcodSnapshotAdapters {
    param(
        [AllowNull()][string]$CommandLine = '"C:\Codex\ChatGPT.exe"',
        [AllowNull()]$ParsedArguments,
        [AllowNull()]$CimProcessId,
        [AllowNull()]$CimParentProcessId,
        [int]$NativeProcessId = 0,
        [int]$SessionId = 1,
        [string]$UserSid = 'S-1-5-21-test',
        [string]$Path = 'C:\Codex\ChatGPT.exe',
        [string]$FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0',
        [int]$ParentPid = 0,
        [string]$SecondCreationTimeUtc = '2026-08-02T00:00:00.0000000Z',
        [bool]$ProbeValid = $true,
        [string]$RendererUrl = 'app://-/index.html',
        $ProbeResult,
        $Counter = $null
    )

    $command = $CommandLine
    $session = $SessionId
    $sid = $UserSid
    $pathValue = $Path
    $family = $FamilyName
    $parent = $ParentPid
    $creationAfter = $SecondCreationTimeUtc
    $probeIsValid = $ProbeValid
    $url = $RendererUrl
    $probeReceipt = $ProbeResult
    $hasExplicitArguments = $PSBoundParameters.ContainsKey('ParsedArguments')
    if ($hasExplicitArguments) {
        $arguments = $ParsedArguments
    } elseif ([string]::IsNullOrWhiteSpace($command)) {
        $arguments = $null
    } else {
        $arguments = @($command.Split(' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim('"') })
    }
    $hasCimPid = $PSBoundParameters.ContainsKey('CimProcessId')
    $cimPid = $CimProcessId
    $hasCimParentPid = $PSBoundParameters.ContainsKey('CimParentProcessId')
    $cimParentPid = $CimParentProcessId
    $nativePid = $NativeProcessId
    $calls = $Counter
    $state = [pscustomobject]@{ NativeReads = 0 }
    return @{
        GetPackageIdentity = {
            if ($null -ne $calls) { $calls.Package++ }
            [pscustomobject]@{
                Found = $true
                FullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
                FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
                Version = '1.0.0.0'
                ExecutablePath = 'C:\Codex\ChatGPT.exe'
            }
        }.GetNewClosure()
        GetCurrentSessionId = { 1 }
        GetCurrentUserSid = { 'S-1-5-21-test' }
        GetNativeProcess = {
            param($ProcessId)
            $state.NativeReads++
            if ($null -ne $calls) { $calls.Native++ }
            [pscustomobject]@{
                Pid = if ($nativePid -eq 0) { $ProcessId } else { $nativePid }
                CreationTimeUtc = if ($state.NativeReads -eq 1) { '2026-08-02T00:00:00.0000000Z' } else { $creationAfter }
                SessionId = $session
                UserSid = $sid
                Path = $pathValue
                PackageFamilyName = $family
            }
        }.GetNewClosure()
        GetCimProcess = {
            param($ProcessId)
            if ($null -ne $calls) { $calls.Cim++ }
            [pscustomobject]@{
                ProcessId = if ($hasCimPid) { $cimPid } else { [uint32]$ProcessId }
                CommandLine = $command
                ParentProcessId = if ($hasCimParentPid) { $cimParentPid } else { [uint32]$parent }
            }
        }.GetNewClosure()
        ParseCommandLine = { param($Value) $arguments }.GetNewClosure()
        ProbeSpecial = {
            param($ProcessId, $RendererPort, $MainPort)
            if ($null -ne $calls) { $calls.Probe++ }
            if ($null -ne $probeReceipt) { return $probeReceipt }
            [pscustomobject]@{ Valid = $probeIsValid; RendererUrl = $url }
        }.GetNewClosure()
    }
}

function New-CcodSpecialStatus {
    [pscustomobject]@{
        pid = 100
        creationTimeUtc = '2026-08-02T00:00:00.0000000Z'
        packageFullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
        packageVersion = '1.0.0.0'
        appAsarSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        mainPort = 41002
        rendererPort = 41001
        mainProbe = 'Closed'
        rendererProbe = 'BridgeValid'
    }
}

try {
    Invoke-CcodTest 'default process adapter recognizes exactly one Codex renderer target' {
        $module = Get-Module ProcessControl
        $targets = @([pscustomobject]@{ type = 'page'; url = 'app://-/index.html' })
        $adapters = & $module {
            param($fixture)
            Get-CcodProcessAdapters -Adapters @{ ReadRendererTargets = { param($Port) return @($fixture) }.GetNewClosure() }
        } $targets
        $probe = & $adapters.ProbeSpecial 100 9335 52359
        Assert-CcodTrue $probe.Valid 'the default probe accepts the exact renderer target'
        Assert-CcodEqual 'app://-/index.html' $probe.RendererUrl 'the default probe preserves the exact renderer URL'

        $adapters = & $module {
            Get-CcodProcessAdapters -Adapters @{ ReadRendererTargets = { param($Port) return @([pscustomobject]@{ type = 'page'; url = 'app://-/index.html' }, [pscustomobject]@{ type = 'page'; url = 'app://-/index.html' }) } }
        }
        $probe = & $adapters.ProbeSpecial 100 9335 52359
        Assert-CcodTrue (-not $probe.Valid) 'duplicate renderer targets fail closed'
    }
} catch {
    throw
}

function Assert-CcodStopResultContract {
    param($Result, [string]$Outcome, [bool]$Stopped, $Snapshot, [string]$Message)

    Assert-CcodEqual 'Outcome,StoppedByController,Snapshot' (($Result.PSObject.Properties.Name) -join ',') "$Message exact properties"
    Assert-CcodEqual $Outcome $Result.Outcome "$Message outcome"
    Assert-CcodEqual $Stopped $Result.StoppedByController "$Message controller receipt"
    Assert-CcodEqual $Snapshot $Result.Snapshot "$Message snapshot"
}

function Assert-CcodTransactionResultContract {
    param($Result, [string]$Outcome, [string]$Message)

    Assert-CcodEqual 'Outcome,Snapshot,Candidates,ConflictOwners' (($Result.PSObject.Properties.Name) -join ',') "$Message exact properties"
    Assert-CcodEqual $Outcome $Result.Outcome "$Message outcome"
    Assert-CcodTrue (@('Confirmed','NoCandidate','Incomplete','Ambiguous','PortConflict') -ccontains $Result.Outcome) "$Message case-exact outcome"
    Assert-CcodTrue ($null -ne $Result.Candidates) "$Message candidates collection exists"
    Assert-CcodTrue ($null -ne $Result.ConflictOwners) "$Message conflict collection exists"
    foreach ($snapshot in @(@($Result.Snapshot) + @($Result.Candidates) + @($Result.ConflictOwners))) {
        if ($null -eq $snapshot) { continue }
        Assert-CcodEqual 'Pid,CreationTimeUtc,SessionId,UserSid,Path,PackageFamilyName,CommandLine,ParentPid,IsTopLevel,Mode,RendererPort,MainPort' `
            (($snapshot.PSObject.Properties.Name) -join ',') "$Message exact exposed snapshot properties"
    }
}

try {
    Invoke-CcodTest 'requires every process snapshot field to match exactly' {
        $expected = New-CcodSnapshot
        $actual = New-CcodSnapshot
        Assert-CcodEqual $true (Test-CcodProcessMatch -Expected $expected -Actual $actual) 'independent exact snapshots match'

        foreach ($mutation in @(
            @{ Name = 'Pid'; Value = 101 },
            @{ Name = 'Pid'; Value = '100' },
            @{ Name = 'CreationTimeUtc'; Value = '2026-08-02T00:00:02.0000000Z' },
            @{ Name = 'SessionId'; Value = 2 },
            @{ Name = 'UserSid'; Value = 'S-1-5-21-other' },
            @{ Name = 'Path'; Value = 'C:\Other\ChatGPT.exe' },
            @{ Name = 'PackageFamilyName'; Value = 'Other.Family' },
            @{ Name = 'CommandLine'; Value = '"C:\Codex\ChatGPT.exe" --type=renderer' },
            @{ Name = 'ParentPid'; Value = 50 },
            @{ Name = 'IsTopLevel'; Value = $false },
            @{ Name = 'IsTopLevel'; Value = 'True' },
            @{ Name = 'Mode'; Value = 'Special' },
            @{ Name = 'RendererPort'; Value = 41001 },
            @{ Name = 'MainPort'; Value = 41002 }
        )) {
            $changed = New-CcodSnapshot
            $changed.($mutation.Name) = $mutation.Value
            Assert-CcodEqual $false (Test-CcodProcessMatch -Expected $expected -Actual $changed) "$($mutation.Name) mismatch is rejected"
        }
    }

    Invoke-CcodTest 'classifies only the current exact package top-level process as ordinary' {
        $ordinary = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters)
        Assert-CcodEqual 'Ordinary' $ordinary.Mode 'exact current root is ordinary'
        Assert-CcodEqual $true $ordinary.IsTopLevel 'ordinary root is top level'
        Assert-CcodEqual $null $ordinary.RendererPort 'ordinary root has no renderer port'

        foreach ($case in @(
            @{ Name = 'renderer child'; Adapters = (New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" --type=renderer' -ParentPid 100) },
            @{ Name = 'other session'; Adapters = (New-CcodSnapshotAdapters -SessionId 2) },
            @{ Name = 'other user'; Adapters = (New-CcodSnapshotAdapters -UserSid 'S-1-5-21-other') },
            @{ Name = 'path mismatch'; Adapters = (New-CcodSnapshotAdapters -Path 'C:\Other\ChatGPT.exe') },
            @{ Name = 'family mismatch'; Adapters = (New-CcodSnapshotAdapters -FamilyName 'Other.Family') }
        )) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -Adapters $case.Adapters
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) is never adopted"
        }
    }

    Invoke-CcodTest 'finds one same-family stale package special root only when its old package path and argv are exact' {
        $current = [pscustomobject]@{
            Found = $true
            FullName = 'OpenAI.Codex_26.814.5517.0_x64__2p2nqsd0c76g0'
            FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
            Version = '26.814.5517.0'
            ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.814.5517.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        }
        $oldPath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.814.5167.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        $oldCommand = '"' + $oldPath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $oldArgs = @($oldPath,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002')
        $oldAdapters = New-CcodSnapshotAdapters -Path $oldPath -CommandLine $oldCommand -ParsedArguments $oldArgs
        $oldAdapters.GetPackageIdentity = { $current }.GetNewClosure()
        $old = Get-CcodProcessSnapshot -ProcessId 4596 -Adapters $oldAdapters
        Assert-CcodEqual $false $old.IsTopLevel 'normal current-package snapshot keeps old-package argv[0] outside the managed root contract'
        Assert-CcodEqual 'Unrelated' $old.Mode 'old package is never adopted as the current managed root'
        $calls = [pscustomobject]@{ Reads = 0 }
        $oldAdapters.GetNativeProcess = { param($ProcessId) $calls.Reads++; [pscustomobject]@{Pid=$ProcessId;CreationTimeUtc='2026-08-02T00:00:00.0000000Z';SessionId=1;UserSid='S-1-5-21-test';Path=$oldPath;PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'} }.GetNewClosure()
        $result = Get-CcodStalePackageRootResult -Package $current -ProcessIds @(4596) -Adapters $oldAdapters

        Assert-CcodEqual 'Confirmed' $result.Outcome 'one verifiable old-version same-family root is a stale remote-server candidate'
        Assert-CcodEqual 4596 $result.Snapshot.Pid 'the exact old root is retained'
        Assert-CcodEqual 6 $calls.Reads 'candidate identity is bracketed and reread before it can be closed'

        $gracefulCalls=[pscustomobject]@{Close=0;Dispose=0};$fakeStaleProcess=[pscustomobject]@{Id=4596}
        $oldAdapters.GetGracefulCloseProcess={param($ProcessId)$fakeStaleProcess}.GetNewClosure()
        $oldAdapters.GetGracefulCloseCreationTimeUtc={param($Process)'2026-08-02T00:00:01.0000000Z'}
        $oldAdapters.CloseGracefulProcess={param($Process)$gracefulCalls.Close++;$true}.GetNewClosure()
        $oldAdapters.DisposeGracefulProcess={param($Process)$gracefulCalls.Dispose++}.GetNewClosure()
        $staleReuse=Request-CcodStaleProcessGracefulCloseIfMatch -Expected $result.Snapshot -Package $current -Adapters $oldAdapters
        Assert-CcodEqual 'IdentityChanged' $staleReuse.Outcome 'raw stale close rejects PID reuse at the production graceful boundary'
        Assert-CcodEqual 0 $gracefulCalls.Close 'raw stale close never signals the replacement process'
        Assert-CcodEqual 1 $gracefulCalls.Dispose 'raw stale graceful process object is disposed after identity proof'

        $oldAdapters.ListProcessIds={@(4596)}
        $staleTree=Get-CcodVerifiedStaleProcessTree -Root $result.Snapshot -Package $current -Adapters $oldAdapters
        Assert-CcodEqual '4596' (($staleTree|ForEach-Object Pid)-join ',') 'default stale-tree composition retains the exact raw root before any close'

        $currentRoot = New-CcodSnapshot -ProcessId 26700 -Path $current.ExecutablePath -Mode Unrelated -RendererPort 41003 -MainPort 41004 -CommandLine ('"' + $current.ExecutablePath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41003 --inspect=127.0.0.1:41004')
        $currentRoot.IsTopLevel = $true
        $currentResult = Get-CcodStalePackageRootResult -Package $current -Snapshots @($currentRoot) -Adapters @{ GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'};GetProcess = { param($ProcessId, $StatusEvidence) $currentRoot } }
        Assert-CcodEqual 'Ambiguous' $currentResult.Outcome 'an equal-version same-family top-level debug root is a conflict but never a stale closure target'

        $futurePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.814.9999.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        $futureAdapters = New-CcodSnapshotAdapters -Path $futurePath -CommandLine ('"' + $futurePath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41005 --inspect=127.0.0.1:41006') -ParsedArguments @($futurePath,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41005','--inspect=127.0.0.1:41006')
        $futureAdapters.GetPackageIdentity = { $current }.GetNewClosure()
        $futureResult = Get-CcodStalePackageRootResult -Package $current -ProcessIds @(26701) -Adapters $futureAdapters
        Assert-CcodEqual 'Ambiguous' $futureResult.Outcome 'a same-family newer package version is a conflict but never a stale closure target'

        $extraDebug = $result.Snapshot | Select-Object *
        $extraDebug.CommandLine = '"' + $oldPath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002 --inspect-brk=127.0.0.1:41003'
        $extraDebugResult = Get-CcodStalePackageRootResult -Package $current -Snapshots @($extraDebug) -Adapters @{
            GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'}
            ParseCommandLine={param($CommandLine)@($oldPath,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002','--inspect-brk=127.0.0.1:41003')}
            GetProcess={param($ProcessId,$StatusEvidence)$extraDebug}.GetNewClosure()
        }
        Assert-CcodEqual 'Ambiguous' $extraDebugResult.Outcome 'extra or conflicting same-family top-level debug argv are a conflict but never a closure target'

        foreach($unsafePath in @(
            'C:\PROGRA~1\WindowsApps\OpenAI.Codex_26.814.5167.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe',
            'C:\Program Files\WindowsApps\OpenAI.Codex_bad-version_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        )){
            $unsafe = New-CcodSnapshot -ProcessId 26702 -Path $unsafePath -Mode Unrelated -RendererPort 41005 -MainPort 41006 -CommandLine ('"' + $unsafePath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41005 --inspect=127.0.0.1:41006')
            $unsafe.IsTopLevel = $true
            $unsafeResult = Get-CcodStalePackageRootResult -Package $current -Snapshots @($unsafe) -Adapters @{ GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'};GetProcess = { param($ProcessId, $StatusEvidence) $unsafe }.GetNewClosure() }
            Assert-CcodEqual 'Ambiguous' $unsafeResult.Outcome 'an unsafe same-family top-level debug path blocks repair but is never targetable'
        }

        $foreign = New-CcodSnapshot -ProcessId 88 -Path $oldPath -PackageFamilyName 'Other.Family' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine ('"' + $oldPath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002')
        $foreign.IsTopLevel = $true
        $foreignResult = Get-CcodStalePackageRootResult -Package $current -Snapshots @($foreign) -Adapters @{ GetProcess = { param($ProcessId, $StatusEvidence) $foreign } }
        Assert-CcodEqual 'NoCandidate' $foreignResult.Outcome 'an unrelated package family is ignored'

        $rawOld = $result.Snapshot
        $otherOld = $rawOld | Select-Object *
        $otherOld.Pid = 4597
        $otherOld.CreationTimeUtc = '2026-08-20T01:02:04.0000000Z'
        $otherOld.RendererPort = 41005
        $otherOld.MainPort = 41006
        $otherOld.CommandLine = '"' + $oldPath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41005 --inspect=127.0.0.1:41006'
        $ambiguous = Get-CcodStalePackageRootResult -Package $current -Snapshots @($rawOld, $otherOld) -Adapters @{ GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'};GetProcess = { param($ProcessId, $StatusEvidence) if ($ProcessId -eq 4596) { $rawOld } else { $otherOld } } }
        Assert-CcodEqual 'Ambiguous' $ambiguous.Outcome 'multiple old same-family remote roots fail closed'

        $malformedSibling = $extraDebug | Select-Object *
        $malformedSibling.Pid = 4598
        $malformedSibling.CreationTimeUtc = '2026-08-20T01:02:05.0000000Z'
        $malformedConflict = Get-CcodStalePackageRootResult -Package $current -Snapshots @($rawOld, $malformedSibling) -Adapters @{
            GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'}
            ParseCommandLine={
                param($CommandLine)
                if($CommandLine -ceq $rawOld.CommandLine){return @($oldArgs)}
                return @($oldPath,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002','--inspect-brk=127.0.0.1:41003')
            }.GetNewClosure()
            GetProcess={param($ProcessId,$StatusEvidence)if($ProcessId -eq 4596){$rawOld}else{$malformedSibling}}.GetNewClosure()
        }
        Assert-CcodEqual 'Ambiguous' $malformedConflict.Outcome 'one exact old root plus a malformed same-family top-level debug sibling fails closed'

        $newerSibling = New-CcodSnapshot -ProcessId 4599 -CreationTimeUtc '2026-08-20T01:02:06.0000000Z' -Path $futurePath -Mode Unrelated -RendererPort 41005 -MainPort 41006 -CommandLine ('"' + $futurePath + '" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41005 --inspect=127.0.0.1:41006')
        $newerConflict = Get-CcodStalePackageRootResult -Package $current -Snapshots @($rawOld, $newerSibling) -Adapters @{
            GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'}
            ParseCommandLine={
                param($CommandLine)
                if($CommandLine -ceq $rawOld.CommandLine){return @($oldArgs)}
                return @($futurePath,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41005','--inspect=127.0.0.1:41006')
            }.GetNewClosure()
            GetProcess={param($ProcessId,$StatusEvidence)if($ProcessId -eq 4596){$rawOld}else{$newerSibling}}.GetNewClosure()
        }
        Assert-CcodEqual 'Ambiguous' $newerConflict.Outcome 'one exact old root plus a newer same-family top-level debug sibling fails closed'

        $reused = $rawOld | Select-Object *
        $reused.CreationTimeUtc = '2026-08-20T01:02:04.0000000Z'
        $reuseReads = [pscustomobject]@{ Count = 0 }
        $reusedResult = Get-CcodStalePackageRootResult -Package $current -Snapshots @($rawOld) -Adapters @{
            GetCurrentSessionId={1};GetCurrentUserSid={'S-1-5-21-test'}
            GetProcess = { param($ProcessId, $StatusEvidence) $script:unused = $StatusEvidence; $reuseReads.Count++; if ($reuseReads.Count -eq 1) { $rawOld } else { $reused } }.GetNewClosure()
        }
        Assert-CcodEqual 'Incomplete' $reusedResult.Outcome 'PID reuse or creation-time drift blocks stale-root closure'

    }

    Invoke-CcodTest 'classifies the current renderer-only CDP launch as an ordinary root' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001'
        $arguments = @('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001')
        $ordinary = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters -CommandLine $command -ParsedArguments $arguments)
        Assert-CcodEqual 'Ordinary' $ordinary.Mode 'renderer-only CDP root is an ordinary Codex launch'
        Assert-CcodEqual $true $ordinary.IsTopLevel 'renderer-only CDP root is top level'
        Assert-CcodEqual $null $ordinary.RendererPort 'renderer-only CDP port is not special evidence'
        Assert-CcodEqual $null $ordinary.MainPort 'renderer-only CDP root has no main inspector'

        $quotedCommand = '"C:\Codex\ChatGPT.exe" "--remote-debugging-address=127.0.0.1" "--remote-debugging-port=41001"'
        $quoted = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters -CommandLine $quotedCommand -ParsedArguments $arguments)
        Assert-CcodEqual 'Ordinary' $quoted.Mode 'quoted whole renderer-only debug tokens stay ordinary'

        foreach ($case in @(
            @{ Name='missing loopback address'; Args=@('C:\Codex\ChatGPT.exe','--remote-debugging-port=41001') },
            @{ Name='non-loopback address'; Args=@('C:\Codex\ChatGPT.exe','--remote-debugging-address=0.0.0.0','--remote-debugging-port=41001') },
            @{ Name='duplicate renderer port'; Args=@('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--remote-debugging-port=41002') },
            @{ Name='malformed renderer port'; Args=@('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=abc') },
            @{ Name='inspector-only debug'; Args=@('C:\Codex\ChatGPT.exe','--inspect=127.0.0.1:41002') }
        )) {
            $caseCommand = '"C:\Codex\ChatGPT.exe" ' + (($case.Args | Select-Object -Skip 1) -join ' ')
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters -CommandLine $caseCommand -ParsedArguments $case.Args)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) is never ordinary"
        }
    }

    Invoke-CcodTest 'uses parsed Windows argv tokens and rejects malformed process metadata' {
        $quotedChild = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters `
            -CommandLine '"C:\Codex\ChatGPT.exe" "--type=renderer"' `
            -ParsedArguments @('C:\Codex\ChatGPT.exe', '--type=renderer') -ParentPid 100)
        Assert-CcodEqual 'Unrelated' $quotedChild.Mode 'quoted child token is still a child after quote removal'
        Assert-CcodEqual $false $quotedChild.IsTopLevel 'quoted child token is never top-level'

        foreach ($case in @(
            @{ Name='empty command line'; Adapters=(New-CcodSnapshotAdapters -CommandLine '') },
            @{ Name='null command line'; Adapters=(New-CcodSnapshotAdapters -CommandLine $null) },
            @{ Name='argv parse failure'; Adapters=(New-CcodSnapshotAdapters -CommandLine 'malformed' -ParsedArguments $null) },
            @{ Name='CIM PID mismatch'; Adapters=(New-CcodSnapshotAdapters -CimProcessId 101) },
            @{ Name='coercive CIM PID'; Adapters=(New-CcodSnapshotAdapters -CimProcessId '100') },
            @{ Name='coercive parent PID'; Adapters=(New-CcodSnapshotAdapters -CimParentProcessId '0') },
            @{ Name='native PID mismatch'; Adapters=(New-CcodSnapshotAdapters -NativeProcessId 101) },
            @{ Name='argv zero mismatch'; Adapters=(New-CcodSnapshotAdapters -ParsedArguments @('C:\Other\ChatGPT.exe')) },
            @{ Name='alternate inspector switch'; Adapters=(New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" --inspect-brk=127.0.0.1:41002' -ParsedArguments @('C:\Codex\ChatGPT.exe','--inspect-brk=127.0.0.1:41002')) },
            @{ Name='bare remote debugging switch'; Adapters=(New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" --remote-debugging' -ParsedArguments @('C:\Codex\ChatGPT.exe','--remote-debugging')) },
            @{ Name='single-dash debug prefix'; Adapters=(New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" -remote-debugging-port=41001' -ParsedArguments @('C:\Codex\ChatGPT.exe','-remote-debugging-port=41001')) },
            @{ Name='slash inspect prefix'; Adapters=(New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" /inspect=127.0.0.1:41002' -ParsedArguments @('C:\Codex\ChatGPT.exe','/inspect=127.0.0.1:41002')) },
            @{ Name='slash child prefix'; Adapters=(New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" /type=renderer' -ParsedArguments @('C:\Codex\ChatGPT.exe','/type=renderer')) }
        )) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -Adapters $case.Adapters
            if ($case.Name -in @('CIM PID mismatch','coercive CIM PID','coercive parent PID','native PID mismatch')) {
                Assert-CcodEqual $null $snapshot "$($case.Name) rejects the snapshot"
            } else {
                Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) is never ordinary"
            }
        }
    }

    Invoke-CcodTest 'classifies special mode only with exact ports status URL and live probe' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $status = New-CcodSpecialStatus
        $special = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $status -Adapters (New-CcodSnapshotAdapters -CommandLine $command)
        Assert-CcodEqual 'Special' $special.Mode 'all independent special evidence matches'
        Assert-CcodEqual 41001 $special.RendererPort 'renderer port is parsed'
        Assert-CcodEqual 41002 $special.MainPort 'main port is parsed'

        foreach ($case in @(
            @{ Name = 'wrong renderer port'; Command = $command.Replace('41001', '41003'); Status = $status; Probe = $true; Url = 'app://-/index.html' },
            @{ Name = 'wrong main port'; Command = $command.Replace('41002', '41004'); Status = $status; Probe = $true; Url = 'app://-/index.html' },
            @{ Name = 'status PID mismatch'; Command = $command; Status = ([pscustomobject]@{ pid=101; creationTimeUtc=$status.creationTimeUtc; packageFullName=$status.packageFullName; packageVersion=$status.packageVersion; rendererPort=41001; mainPort=41002 }); Probe = $true; Url = 'app://-/index.html' },
            @{ Name = 'query-bearing renderer URL'; Command = $command; Status = $status; Probe = $true; Url = 'app://-/index.html?overlay=1' },
            @{ Name = 'failed live probe'; Command = $command; Status = $status; Probe = $false; Url = 'app://-/index.html' }
        )) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $case.Status -Adapters (New-CcodSnapshotAdapters -CommandLine $case.Command -ProbeValid $case.Probe -RendererUrl $case.Url)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) cannot prove special identity"
        }
    }

    Invoke-CcodTest 'requires exact whole debug tokens with no duplicate or conflicting switches' {
        $status = New-CcodSpecialStatus
        $validArguments = @(
            'C:\Codex\ChatGPT.exe',
            '--remote-debugging-address=127.0.0.1',
            '--remote-debugging-port=41001',
            '--inspect=127.0.0.1:41002'
        )
        $quotedCommand = '"C:\Codex\ChatGPT.exe" "--remote-debugging-address=127.0.0.1" "--remote-debugging-port=41001" "--inspect=127.0.0.1:41002"'
        $quoted = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $status -Adapters (New-CcodSnapshotAdapters -CommandLine $quotedCommand -ParsedArguments $validArguments)
        Assert-CcodEqual 'Special' $quoted.Mode 'quoted whole debug tokens retain their argv meaning'

        foreach ($case in @(
            @{ Name='duplicate address'; Args=$validArguments + '--remote-debugging-address=127.0.0.1' },
            @{ Name='conflicting address'; Args=$validArguments + '--remote-debugging-address=0.0.0.0' },
            @{ Name='duplicate renderer port'; Args=$validArguments + '--remote-debugging-port=41001' },
            @{ Name='malformed renderer port'; Args=$validArguments + '--remote-debugging-port=abc' },
            @{ Name='alternate inspector'; Args=$validArguments + '--inspect-brk=127.0.0.1:41002' }
        )) {
            $command = '"C:\Codex\ChatGPT.exe" ' + ($case.Args[1..($case.Args.Count - 1)] -join ' ')
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $status -Adapters (New-CcodSnapshotAdapters -CommandLine $command -ParsedArguments $case.Args)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) cannot prove special mode"
        }
    }

    Invoke-CcodTest 'requires exact status and probe proof schemas and types' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $base = New-CcodSpecialStatus
        $coercivePid = $base.PSObject.Copy(); $coercivePid.pid = '100'
        $coercivePort = $base.PSObject.Copy(); $coercivePort.rendererPort = '41001'
        $extraStatus = $base.PSObject.Copy(); $extraStatus | Add-Member -NotePropertyName extra -NotePropertyValue 'unsafe'
        $missingStatus = $base | Select-Object * -ExcludeProperty appAsarSha256
        foreach ($statusCase in @($coercivePid, $coercivePort, $extraStatus, $missingStatus)) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $statusCase -Adapters (New-CcodSnapshotAdapters -CommandLine $command)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode 'coercive missing or extra status proof fails closed'
        }

        foreach ($probe in @(
            [pscustomobject]@{ Valid='True'; RendererUrl='app://-/index.html' },
            [pscustomobject]@{ Valid=$true; RendererUrl='app://-/index.html'; Extra='unsafe' }
        )) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $base -Adapters (New-CcodSnapshotAdapters -CommandLine $command -ProbeResult $probe)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode 'probe proof shape and bool type are exact'
        }
    }

    Invoke-CcodTest 'accepts StateStore Int64 proof numbers only when losslessly in range' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $longProof = New-CcodSpecialStatus
        $longProof.pid = [long]100
        $longProof.rendererPort = [long]41001
        $longProof.mainPort = [long]41002
        $special = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $longProof -Adapters (New-CcodSnapshotAdapters -CommandLine $command)
        Assert-CcodEqual 'Special' $special.Mode 'StateStore-valid Int64 numbers normalize to the snapshot contract'

        foreach ($invalid in @(
            @{ Name='PID overflow'; Field='pid'; Value=([long][int]::MaxValue + 1) },
            @{ Name='zero PID'; Field='pid'; Value=[long]0 },
            @{ Name='renderer port overflow'; Field='rendererPort'; Value=[long]65536 },
            @{ Name='zero main port'; Field='mainPort'; Value=[int]0 },
            @{ Name='floating PID'; Field='pid'; Value=[double]100 },
            @{ Name='Boolean port'; Field='mainPort'; Value=$true }
        )) {
            $proof = (New-CcodSpecialStatus).PSObject.Copy()
            $proof.($invalid.Field) = $invalid.Value
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $proof -Adapters (New-CcodSnapshotAdapters -CommandLine $command)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($invalid.Name) fails closed"
        }
    }

    Invoke-CcodTest 'rejects a snapshot when creation changes across CIM metadata' {
        $calls = [pscustomobject]@{ Package = 0; Native = 0; Cim = 0; Probe = 0 }
        $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters -SecondCreationTimeUtc '2026-08-02T00:00:02.0000000Z' -Counter $calls)
        Assert-CcodEqual $null $snapshot 'PID reuse during metadata collection fails closed'
        Assert-CcodEqual 1 $calls.Package 'package identity is dynamically resolved once for this read'
        Assert-CcodEqual 2 $calls.Native 'native identity brackets CIM metadata'
        Assert-CcodEqual 1 $calls.Cim 'CIM is used only for command and parent metadata'
        Assert-CcodEqual 0 $calls.Probe 'unstable identity is never probed'
    }

    Invoke-CcodTest 'never calls the stop boundary after exit or identity change' {
        $expected = New-CcodSnapshot
        $calls = [pscustomobject]@{ Stop = 0 }
        $exited = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) $null }
            StopProcess = { $calls.Stop++; throw 'must not run' }.GetNewClosure()
        }
        Assert-CcodStopResultContract -Result $exited -Outcome SourceExited -Stopped $false -Snapshot $null -Message 'natural exit'

        $reused = New-CcodSnapshot -CreationTimeUtc '2026-08-02T00:00:02.0000000Z'
        $changed = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) $reused }.GetNewClosure()
            StopProcess = { $calls.Stop++; throw 'must not run' }.GetNewClosure()
        }
        Assert-CcodStopResultContract -Result $changed -Outcome IdentityChanged -Stopped $false -Snapshot $reused -Message 'PID reuse'
        Assert-CcodEqual 0 $calls.Stop 'dangerous boundary is unreachable without an exact reread'
    }

    Invoke-CcodTest 'default graceful-close adapter rejects PID reuse on the same process object before signaling it' {
        $expected=New-CcodSnapshot
        $calls=[pscustomobject]@{Close=0;Dispose=0}
        $fakeProcess=[pscustomobject]@{Id=100}
        $result=Request-CcodProcessGracefulCloseIfMatch -Expected $expected -Adapters @{
            GetProcess={param($ProcessId,$StatusEvidence)$expected}.GetNewClosure()
            GetGracefulCloseProcess={param($ProcessId)$fakeProcess}.GetNewClosure()
            GetGracefulCloseCreationTimeUtc={param($Process)'2026-08-02T00:00:01.0000000Z'}
            CloseGracefulProcess={param($Process)$calls.Close++;$true}.GetNewClosure()
            DisposeGracefulProcess={param($Process)$calls.Dispose++}.GetNewClosure()
        }
        Assert-CcodEqual 'IdentityChanged' $result.Outcome 'production graceful boundary refuses a reused PID before CloseMainWindow'
        Assert-CcodEqual 0 $calls.Close 'PID reuse never signals the replacement process'
        Assert-CcodEqual 1 $calls.Dispose 'the checked process object is still disposed'
    }

    Invoke-CcodTest 'requires an exact confirmed stop receipt' {
        $expected = New-CcodSnapshot
        $calls = [pscustomobject]@{ Stop = 0; ProcessId = 0; Timeout = 0; Snapshot = $null }
        $receipt = [pscustomobject]@{
            Outcome = 'StoppedByController'
            StoppedByController = $true
            Pid = 100
            CreationTimeUtc = '2026-08-02T00:00:00.0000000Z'
        }
        $result = Stop-CcodProcessIfMatch -Expected $expected -TimeoutMilliseconds 4321 -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = {
                param($Snapshot, $TimeoutMilliseconds)
                $calls.Stop++
                $calls.ProcessId = $Snapshot.Pid
                $calls.Timeout = $TimeoutMilliseconds
                $calls.Snapshot = $Snapshot
                $receipt
            }.GetNewClosure()
        }
        Assert-CcodStopResultContract -Result $result -Outcome Stopped -Stopped $true -Snapshot $calls.Snapshot -Message 'confirmed stop receipt'
        Assert-CcodEqual 1 $calls.Stop 'stop boundary is called once'
        Assert-CcodEqual 100 $calls.ProcessId 'exact reread snapshot is passed to the stop boundary'
        Assert-CcodEqual 4321 $calls.Timeout 'timeout is passed without substitution'
        Assert-CcodEqual $true (Test-CcodProcessMatch -Expected $expected -Actual $calls.Snapshot) 'stop receives the exact actual snapshot'

        $unconfirmed = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) $expected }.GetNewClosure()
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) $null }
        }
        Assert-CcodStopResultContract -Result $unconfirmed -Outcome StopUnconfirmed -Stopped $false -Snapshot $expected -Message 'missing stop receipt'

        $coercedReceipt = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = {
                param($Snapshot, $TimeoutMilliseconds)
                [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController=$true; Pid='100'; CreationTimeUtc='2026-08-02T00:00:00.0000000Z' }
            }
        }
        Assert-CcodEqual 'StopUnconfirmed' $coercedReceipt.Outcome 'coercive receipt identity is never confirmation'

        foreach ($badReceipt in @(
            [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController='True'; Pid=100; CreationTimeUtc='2026-08-02T00:00:00.0000000Z' },
            [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController=$true; Pid=100; CreationTimeUtc=[DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z') }
        )) {
            $unsafeReceipt = $badReceipt
            $resultFromUnsafeReceipt = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
                GetProcess = { param($ProcessId) New-CcodSnapshot }
                StopProcess = { param($Snapshot, $TimeoutMilliseconds) $unsafeReceipt }.GetNewClosure()
            }
            Assert-CcodEqual 'StopUnconfirmed' $resultFromUnsafeReceipt.Outcome 'receipt confirmation fields are type exact'
        }

        $exitedReceipt = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId, $StatusEvidence) $expected }.GetNewClosure()
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) [pscustomobject]@{ Outcome='ExitedBeforeStop'; StoppedByController=$false } }
        }
        Assert-CcodStopResultContract -Result $exitedReceipt -Outcome SourceExited -Stopped $false -Snapshot $null -Message 'internal pre-stop exit'
    }

    Invoke-CcodTest 'distinguishes access denial and delayed exit' {
        $expected = New-CcodSnapshot
        $denied = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) [pscustomobject]@{ Outcome = 'AccessDenied'; StoppedByController = $false } }
        }
        Assert-CcodEqual 'StopUnconfirmed' $denied.Outcome 'access failure maps to the public unconfirmed outcome'
        Assert-CcodEqual $false $denied.StoppedByController 'denial never authorizes launch'

        $delayed = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) [pscustomobject]@{ Outcome = 'TimedOut'; StoppedByController = $false } }
        }
        Assert-CcodEqual 'StopUnconfirmed' $delayed.Outcome 'still-running exact handle is publicly unconfirmed'
        Assert-CcodEqual $false $delayed.StoppedByController 'delayed exit never authorizes launch'
    }

    Invoke-CcodTest 'passes explicit evidence when exactly rereading and stopping a validated Special root' {
        $status = New-CcodSpecialStatus
        $expected = New-CcodSnapshot -Mode Special -RendererPort 41001 -MainPort 41002 `
            -CommandLine '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $observed = [pscustomobject]@{ Status = $null }
        $result = Stop-CcodProcessIfMatch -Expected $expected -StatusEvidence $status -Adapters @{
            GetProcess = { param($ProcessId, $StatusEvidence) $observed.Status = $StatusEvidence; $expected }.GetNewClosure()
            StopProcess = {
                param($Snapshot, $TimeoutMilliseconds)
                [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController=$true; Pid=100; CreationTimeUtc='2026-08-02T00:00:00.0000000Z' }
            }
        }
        Assert-CcodEqual 'Stopped' $result.Outcome 'validated Special identity can be exactly reproduced and stopped'
        Assert-CcodEqual $status $observed.Status 'Special status proof reaches the reread adapter'
    }

    Invoke-CcodTest 'collects only identity-verified descendants whose parent chain reaches the root' {
        $root = New-CcodSnapshot
        $child = New-CcodSnapshot -ProcessId 101 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated -CommandLine '"C:\Codex\ChatGPT.exe" --type=renderer'
        $grandchild = New-CcodSnapshot -ProcessId 102 -CreationTimeUtc '2026-08-02T00:00:02.0000000Z' -ParentPid 101 -IsTopLevel $false -Mode Unrelated -CommandLine '"C:\Codex\ChatGPT.exe" --type=gpu-process'
        $otherSession = New-CcodSnapshot -ProcessId 103 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -SessionId 2 -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $older = New-CcodSnapshot -ProcessId 104 -CreationTimeUtc '2026-08-01T23:59:59.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $disconnected = New-CcodSnapshot -ProcessId 105 -CreationTimeUtc '2026-08-02T00:00:03.0000000Z' -ParentPid 999 -IsTopLevel $false -Mode Unrelated
        $wrongPath = New-CcodSnapshot -ProcessId 106 -CreationTimeUtc '2026-08-02T00:00:03.0000000Z' -Path 'C:\Other\ChatGPT.exe' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $map = @{
            100 = $root; 101 = $child; 102 = $grandchild; 103 = $otherSession
            104 = $older; 105 = $disconnected; 106 = $wrongPath
        }
        $reads = [pscustomobject]@{ Count = 0 }
        $tree = @(Get-CcodVerifiedProcessTree -Root $root -Adapters @{
            ListProcessIds = { @(100, 101, 102, 103, 104, 105, 106) }
            GetProcess = { param($ProcessId) $reads.Count++; $map[[int]$ProcessId] }.GetNewClosure()
        })
        Assert-CcodEqual 3 $tree.Count 'only root and two verified descendants remain'
        Assert-CcodEqual '100,101,102' (($tree.Pid | Sort-Object) -join ',') 'untrusted parent links never enter the tree'
        Assert-CcodTrue ($reads.Count -ge 10) 'included tree identities are reread before return'
    }

    Invoke-CcodTest 'rejects a child older than its exact current parent and drops mutated rereads' {
        $root = New-CcodSnapshot
        $reusedParent = New-CcodSnapshot -ProcessId 101 -CreationTimeUtc '2026-08-02T00:00:10.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $staleChild = New-CcodSnapshot -ProcessId 102 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -ParentPid 101 -IsTopLevel $false -Mode Unrelated
        $map = @{ 100=$root; 101=$reusedParent; 102=$staleChild }
        $tree = @(Get-CcodVerifiedProcessTree -Root $root -Adapters @{
            ListProcessIds = { @(100,101,102) }
            GetProcess = { param($ProcessId, $StatusEvidence) $map[[int]$ProcessId] }.GetNewClosure()
        })
        Assert-CcodEqual '100,101' (($tree.Pid | Sort-Object) -join ',') 'child creation must not predate its exact parent creation'

        $stableChild = New-CcodSnapshot -ProcessId 103 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $mutatedChild = New-CcodSnapshot -ProcessId 103 -CreationTimeUtc '2026-08-02T00:00:02.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $counts = @{ 100=0; 103=0 }
        $mutationTree = @(Get-CcodVerifiedProcessTree -Root $root -Adapters @{
            ListProcessIds = { @(100,103) }
            GetProcess = {
                param($ProcessId, $StatusEvidence)
                $counts[[int]$ProcessId]++
                if ([int]$ProcessId -eq 103 -and $counts[103] -gt 1) { return $mutatedChild }
                if ([int]$ProcessId -eq 103) { return $stableChild }
                $root
            }.GetNewClosure()
        })
        Assert-CcodEqual '100' (($mutationTree.Pid | Sort-Object) -join ',') 'identity mutation on final reread removes the node'
        Assert-CcodTrue ($counts[103] -ge 2) 'included child is actually reread'
    }

    Invoke-CcodTest 'passes status evidence while rereading a Special tree root' {
        $status = New-CcodSpecialStatus
        $root = New-CcodSnapshot -Mode Special -RendererPort 41001 -MainPort 41002 -CommandLine 'special'
        $child = New-CcodSnapshot -ProcessId 101 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $seen = [pscustomobject]@{ RootEvidenceCount = 0 }
        $tree = @(Get-CcodVerifiedProcessTree -Root $root -StatusEvidence $status -Adapters @{
            ListProcessIds = { @(100,101) }
            GetProcess = {
                param($ProcessId, $StatusEvidence)
                if ([int]$ProcessId -eq 100 -and $StatusEvidence -eq $status) { $seen.RootEvidenceCount++ }
                if ([int]$ProcessId -eq 100) { return $root }
                $child
            }.GetNewClosure()
        })
        Assert-CcodEqual '100,101' (($tree.Pid | Sort-Object) -join ',') 'validated Special root retains its exact child tree'
        Assert-CcodTrue ($seen.RootEvidenceCount -ge 2) 'Special root proof is supplied on initial and final rereads'
    }

    Invoke-CcodTest 'adopts exactly one special transaction candidate' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $validArgv = @('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002')
        $expected = New-CcodSnapshot -ProcessId 200 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $wrongPorts = New-CcodSnapshot -ProcessId 201 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -Mode Unrelated -RendererPort 41003 -MainPort 41002 -CommandLine $command.Replace('41001','41003')
        $tooOld = New-CcodSnapshot -ProcessId 202 -CreationTimeUtc '2026-08-01T23:59:59.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $otherSession = New-CcodSnapshot -ProcessId 203 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -SessionId 2 -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $wrongArgv = New-CcodSnapshot -ProcessId 205 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine ($command + ' --remote-debugging-address=0.0.0.0')
        $map = @{ 200 = $expected; 201 = $wrongPorts; 202 = $tooOld; 203 = $otherSession; 205 = $wrongArgv }
        $adapters = @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            ListProcessIds = { @(200, 201, 202, 203, 205) }
            GetProcess = { param($ProcessId, $StatusEvidence) $map[[int]$ProcessId] }.GetNewClosure()
            ParseCommandLine = {
                param($Value)
                if ($Value -match '0\.0\.0\.0') { return $validArgv + '--remote-debugging-address=0.0.0.0' }
                if ($Value -match '41003') { return @('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=41003','--inspect=127.0.0.1:41002') }
                $validArgv
            }.GetNewClosure()
            GetListeningPortOwnerPids = { param($Port, $Address) @(200) }
        }
        $candidate = Find-CcodTransactionProcess -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $adapters
        Assert-CcodEqual 200 $candidate.Pid 'the sole pre-status crash-window candidate is adopted with startup proof'
        Assert-CcodTrue ($null -ne (Get-Command Get-CcodTransactionProcessResult -ErrorAction SilentlyContinue)) 'detailed transaction result is exported publicly'
        $confirmedResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $adapters
        Assert-CcodTransactionResultContract -Result $confirmedResult -Outcome Confirmed -Message 'confirmed transaction'
        Assert-CcodEqual 200 $confirmedResult.Snapshot.Pid 'confirmed result exposes the exact adopted snapshot'
        Assert-CcodEqual '200' (($confirmedResult.Candidates.Pid | Sort-Object) -join ',') 'confirmed result preserves its exact candidate'
        Assert-CcodEqual 0 @($confirmedResult.ConflictOwners).Count 'confirmed result has no conflict owners'

        $second = New-CcodSnapshot -ProcessId 204 -CreationTimeUtc '2026-08-02T00:00:06.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $map[204] = $second
        $ambiguousAdapters = $adapters.Clone()
        $ambiguousAdapters.ListProcessIds = { @(200, 204) }
        $ambiguous = Find-CcodTransactionProcess -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $ambiguousAdapters
        Assert-CcodEqual $null $ambiguous 'multiple exact transaction candidates fail closed'
        $ambiguousResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $ambiguousAdapters
        Assert-CcodTransactionResultContract -Result $ambiguousResult -Outcome Ambiguous -Message 'ambiguous transaction'
        Assert-CcodEqual $null $ambiguousResult.Snapshot 'ambiguous result never selects a snapshot'
        Assert-CcodEqual '200,204' (($ambiguousResult.Candidates.Pid | Sort-Object) -join ',') 'ambiguous result exposes only exact candidates'
        Assert-CcodEqual 0 @($ambiguousResult.ConflictOwners).Count 'ambiguous result has no conflict owners'

        $noCandidateAdapters = $adapters.Clone()
        $noCandidateAdapters.ListProcessIds = { @() }
        $noCandidateAdapters.GetListeningPortOwnerPids = { param($Port, $Address) @() }
        $noCandidateResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $noCandidateAdapters
        Assert-CcodTransactionResultContract -Result $noCandidateResult -Outcome NoCandidate -Message 'empty transaction'
        Assert-CcodEqual $null $noCandidateResult.Snapshot 'no-candidate result has no selected snapshot'
        Assert-CcodEqual 0 @($noCandidateResult.Candidates).Count 'no-candidate result has no candidates'
        Assert-CcodEqual 0 @($noCandidateResult.ConflictOwners).Count 'no-candidate result has no listener owners'

        $lagAdapters = $adapters.Clone()
        $lagAdapters.ListProcessIds = { @() }
        $lagAdapters.GetListeningPortOwnerPids = { param($Port, $Address) @(200) }
        $lagResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $lagAdapters
        Assert-CcodTransactionResultContract -Result $lagResult -Outcome Incomplete -Message 'enumeration lag'
        Assert-CcodEqual $null $lagResult.Snapshot 'enumeration lag cannot select a snapshot'
        Assert-CcodEqual 0 @($lagResult.Candidates).Count 'enumeration lag has no enumerated candidate'
        Assert-CcodEqual 0 @($lagResult.ConflictOwners).Count 'same-transaction owner is not called a conflict'

        $invalidProofAdapters = $adapters.Clone()
        $invalidProofAdapters.ListProcessIds = { @(200) }
        $invalidProofAdapters.GetListeningPortOwnerPids = { param($Port, $Address) @(999) }
        $invalid = Find-CcodTransactionProcess -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $invalidProofAdapters
        Assert-CcodEqual $null $invalid 'invalid endpoint ownership proof cannot be adopted'
        $invalidProofResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $invalidProofAdapters
        Assert-CcodTransactionResultContract -Result $invalidProofResult -Outcome Incomplete -Message 'unproven listener owner'
        Assert-CcodEqual 0 @($invalidProofResult.ConflictOwners).Count 'unproven owner data is not exposed'

        $adapterErrorAdapters = $adapters.Clone()
        $adapterErrorAdapters.ListProcessIds = { throw 'fixture enumeration failure' }
        $adapterErrorResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $adapterErrorAdapters
        Assert-CcodTransactionResultContract -Result $adapterErrorResult -Outcome Incomplete -Message 'adapter failure'
        Assert-CcodEqual 0 @($adapterErrorResult.Candidates).Count 'adapter errors do not leak partial candidates'
        Assert-CcodEqual 0 @($adapterErrorResult.ConflictOwners).Count 'adapter errors do not leak owner data'

        $foreignOwner = New-CcodSnapshot -ProcessId 999 -CreationTimeUtc '2026-08-02T00:00:03.0000000Z' -Path 'C:\Other\foreign.exe' -PackageFamilyName 'Other.Family' -Mode Unrelated -IsTopLevel $false
        $foreignOwner | Add-Member -NotePropertyName AdapterPrivateData -NotePropertyValue 'must not escape'
        $conflictAdapters = $adapters.Clone()
        $conflictAdapters.ListProcessIds = { @(200) }
        $conflictAdapters.GetListeningPortOwnerPids = { param($Port, $Address) @(999) }
        $conflictAdapters.GetProcess = {
            param($ProcessId, $StatusEvidence)
            if ([int]$ProcessId -eq 999) { return $foreignOwner }
            $expected
        }.GetNewClosure()
        $conflictResult = Get-CcodTransactionProcessResult -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $conflictAdapters
        Assert-CcodTransactionResultContract -Result $conflictResult -Outcome PortConflict -Message 'proven foreign listener'
        Assert-CcodEqual $null $conflictResult.Snapshot 'port conflict never selects a candidate'
        Assert-CcodEqual '200' (($conflictResult.Candidates.Pid | Sort-Object) -join ',') 'port conflict retains the exact canonical candidate'
        Assert-CcodEqual '999' (($conflictResult.ConflictOwners.Pid | Sort-Object) -join ',') 'port conflict exposes the exact proven owner'

        $ownerReuseState = [pscustomobject]@{ OwnerReads=0 }
        $reusedOwner = New-CcodSnapshot -ProcessId 200 -CreationTimeUtc '2026-08-02T00:00:09.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $ownerReuseAdapters = $adapters.Clone()
        $ownerReuseAdapters.ListProcessIds = { @(200) }
        $ownerReuseAdapters.GetListeningPortOwnerPids = {
            param($Port, $Address)
            $ownerReuseState.OwnerReads++
            @(200)
        }.GetNewClosure()
        $ownerReuseAdapters.GetProcess = {
            param($ProcessId, $StatusEvidence)
            if ($ownerReuseState.OwnerReads -ge 4) { return $reusedOwner }
            $expected
        }.GetNewClosure()
        $reused = Find-CcodTransactionProcess -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $ownerReuseAdapters
        Assert-CcodEqual $null $reused 'owner PID reuse after the final listener mapping prevents confirmation'
    }

    Invoke-CcodTest 'reserves a nonexcluded IPv4 loopback port' {
        $state = [pscustomobject]@{ Index = 0; Address = $null }
        $ports = @(41001, 41002)
        $port = Get-CcodAvailableLoopbackPort -ExcludedPorts @(41001) -Adapters @{
            ReserveLoopbackPort = {
                param($Address)
                $state.Address = $Address
                $value = $ports[$state.Index]
                $state.Index++
                $value
            }.GetNewClosure()
        }
        Assert-CcodEqual 41002 $port 'excluded reservation is retried'
        Assert-CcodEqual '127.0.0.1' $state.Address 'reservation binds exact IPv4 loopback'
    }

    Invoke-CcodTest 'native argv adapter follows Windows quote removal semantics' {
        $module = Get-Module ProcessControl
        $arguments = @(& $module {
            $adapter = Get-CcodProcessAdapters
            & $adapter.ParseCommandLine '"C:\Program Files\Codex\ChatGPT.exe" "--type=renderer"'
        })
        Assert-CcodEqual 2 $arguments.Count 'native parser returns two whole argv tokens'
        Assert-CcodEqual 'C:\Program Files\Codex\ChatGPT.exe' $arguments[0] 'quoted executable is one token'
        Assert-CcodEqual '--type=renderer' $arguments[1] 'quoted child flag is returned without quote characters'
    }

    Invoke-CcodTest 'native TCP table adapter observes a safe local listener owner' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $port = [int]$listener.LocalEndpoint.Port
            $expectedOwner = [int]$PID
            $module = Get-Module ProcessControl
            $owners = @(& $module {
                param($FixturePort)
                $adapter = Get-CcodProcessAdapters
                & $adapter.GetListeningPortOwnerPids $FixturePort '127.0.0.1'
            } $port)
            Assert-CcodTrue ($owners -contains $expectedOwner) 'AF_INET listener table reports this fixture process PID'
        } finally {
            $listener.Stop()
        }
    }

    Invoke-CcodTest 'accepts port closure only after explicit connection refusal' {
        $clock = [pscustomobject]@{ Tick = 0; Delay = 0 }
        $times = @(
            [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z'),
            [DateTimeOffset]::Parse('2026-08-02T00:00:00.0100000Z')
        )
        $probes = [System.Collections.Queue]::new()
        $probes.Enqueue('Open')
        $probes.Enqueue('Refused')
        $closed = Wait-CcodPortClosed -Port 41001 -TimeoutMilliseconds 1000 -PollMilliseconds 10 -Adapters @{
            GetUtcNow = { $value = $times[[Math]::Min($clock.Tick, $times.Count - 1)]; $clock.Tick++; $value }.GetNewClosure()
            ProbeLoopbackPort = { param($Port) $probes.Dequeue() }.GetNewClosure()
            Delay = { param($Milliseconds) $clock.Delay += $Milliseconds }.GetNewClosure()
        }
        Assert-CcodEqual $true $closed 'explicit refusal proves the endpoint closed'
        Assert-CcodEqual 10 $clock.Delay 'open listener is polled rather than treated as closed'

        $notClosed = Wait-CcodPortClosed -Port 41001 -TimeoutMilliseconds 10 -PollMilliseconds 5 -Adapters @{
            GetUtcNow = { [DateTimeOffset]::Parse('2026-08-02T00:00:01.0000000Z') }
            ProbeLoopbackPort = { param($Port) 'Error' }
            Delay = { param($Milliseconds) throw 'must not delay after unrelated error' }
        }
        Assert-CcodEqual $false $notClosed 'unrelated socket errors never prove closure'
    }

    Invoke-CcodTest 'adopts an existing ordinary root before starting recovery' {
        $ordinary = New-CcodSnapshot -ProcessId 300
        $calls = [pscustomobject]@{ Start = 0; Package = 0 }
        $result = Start-CcodProcess -Mode Ordinary -Adapters @{
            GetPackageIdentity = { $calls.Package++; [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }.GetNewClosure()
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            ListProcessIds = { @(300) }
            GetProcess = { param($ProcessId, $StatusEvidence) $ordinary }.GetNewClosure()
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) $calls.Start++; throw 'must not start' }.GetNewClosure()
        }
        Assert-CcodEqual 'Adopted' $result.Outcome 'recovery adopts an exact live ordinary root'
        Assert-CcodEqual 300 $result.Snapshot.Pid 'adopted identity is returned'
        Assert-CcodEqual 0 $calls.Start 'adoption prevents a duplicate launch'
        Assert-CcodEqual 1 $calls.Package 'launch path is dynamically resolved even when adopting'
    }

    Invoke-CcodTest 'activates an ordinary packaged Codex by exact AUMID instead of launching the WindowsApps executable' {
        $calls = [pscustomobject]@{ Packaged = 0; Direct = 0; Aumid = $null }
        $result = Start-CcodProcess -Mode Ordinary -Adapters @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            ListProcessIds = { @() }
            GetProcess = { param($ProcessId, $StatusEvidence) $null }
            ActivatePackagedApplication = {
                param($AppUserModelId)
                $calls.Packaged++
                $calls.Aumid = $AppUserModelId
                [pscustomobject]@{ Id = 700 }
            }.GetNewClosure()
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) $calls.Direct++; throw 'ordinary packaged activation must not use the executable path' }.GetNewClosure()
        }
        Assert-CcodEqual 'Started' $result.Outcome 'ordinary packaged activation returns started'
        Assert-CcodEqual 1 $calls.Packaged 'packaged activation boundary is called once'
        Assert-CcodEqual 'OpenAI.Codex_2p2nqsd0c76g0!App' $calls.Aumid 'exact current Codex AUMID is used'
        Assert-CcodEqual 0 $calls.Direct 'ordinary activation never executes the WindowsApps binary directly'
        Assert-CcodEqual 700 $result.Process.Id 'activation receipt is preserved for diagnostics'
    }

    Invoke-CcodTest 'default packaged activation uses Explorer AppsFolder without embedding a COM activator' {
        $source = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\persistence\modules\ProcessControl.psm1') -Raw
        Assert-CcodTrue ($source -cnotmatch 'ApplicationActivationManager|PackagedApplicationV1|45BA127D-10A8-46EA-8AB7-56EA9078943C') 'packaged installer source contains no embedded COM activator signature'
        Assert-CcodTrue ($source -cmatch 'shell:AppsFolder\\') 'packaged activation uses the standard Windows AppsFolder shell route'

        $call = [pscustomobject]@{ Path=$null; Arguments=@(); WindowStyle='unset' }
        $start = {
            param($FilePath,$Arguments,$WindowStyle)
            $call.Path=$FilePath;$call.Arguments=@($Arguments);$call.WindowStyle=$WindowStyle
            [pscustomobject]@{ Id=701 }
        }.GetNewClosure()
        $module = Get-Module -Name ProcessControl -ErrorAction Stop
        $receipt = & $module {
            param($StartCallback)
            $adapter = Get-CcodProcessAdapters -Adapters @{ StartProcess=$StartCallback }
            & $adapter.ActivatePackagedApplication 'OpenAI.Codex_2p2nqsd0c76g0!App'
        } $start
        Assert-CcodEqual ([IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe'))) $call.Path 'AppsFolder activation uses the system Explorer path'
        Assert-CcodEqual 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App' ($call.Arguments -join ',') 'AppsFolder activation carries only the exact Codex AUMID'
        Assert-CcodEqual $null $call.WindowStyle 'AppsFolder activation is visible'
        Assert-CcodEqual 701 $receipt.Id 'shell activation receipt is preserved'
    }

    Invoke-CcodTest 'rechecks special ports and launches Codex visibly' {
        $calls = [pscustomobject]@{ Start = 0; Availability = @(); Path = $null; Arguments = @(); WindowStyle = 'unset' }
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $candidate = New-CcodSnapshot -ProcessId 400 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $common = @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            TestLoopbackPortAvailable = { param($Port, $Address) $calls.Availability += "$Address`:$Port"; $true }.GetNewClosure()
            GetUtcNow = { [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z') }
            Delay = { param($Milliseconds) throw 'immediate evidence must not delay' }
            ListProcessIds = { @(400) }
            GetProcess = { param($ProcessId, $StatusEvidence) $candidate }.GetNewClosure()
            ParseCommandLine = { param($Value) @('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002') }
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            GetListeningPortOwnerPids = { param($Port, $Address) @(400) }
            StartProcess = {
                param($FilePath, $Arguments, $WindowStyle)
                $calls.Start++
                $calls.Path = $FilePath
                $calls.Arguments = @($Arguments)
                $calls.WindowStyle = $WindowStyle
                [pscustomobject]@{ Id = 400 }
            }.GetNewClosure()
        }
        $started = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -Adapters $common
        Assert-CcodEqual 'Started' $started.Outcome 'special process launch returns started'
        Assert-CcodEqual 1 $calls.Start 'special launch boundary is called once'
        Assert-CcodEqual '127.0.0.1:41001,127.0.0.1:41002' ($calls.Availability -join ',') 'both ports are rechecked immediately before launch'
        Assert-CcodEqual 'C:\Codex\ChatGPT.exe' $calls.Path 'dynamic package entrypoint is used'
        Assert-CcodEqual $null $calls.WindowStyle 'Codex window is never hidden'
        Assert-CcodEqual '--remote-debugging-address=127.0.0.1,--remote-debugging-port=41001,--inspect=127.0.0.1:41002' ($calls.Arguments -join ',') 'special arguments are exact'

        $blockedCalls = [pscustomobject]@{ Start = 0 }
        $blockedAdapters = $common.Clone()
        $blockedAdapters.TestLoopbackPortAvailable = { param($Port, $Address) $Port -eq 41001 }
        $blockedAdapters.StartProcess = { param($FilePath, $Arguments, $WindowStyle) $blockedCalls.Start++; throw 'must not start' }.GetNewClosure()
        $blocked = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -Adapters $blockedAdapters
        Assert-CcodEqual 'PortUnavailable' $blocked.Outcome 'binding race fails the special launch'
        Assert-CcodEqual 0 $blockedCalls.Start 'unavailable port is rejected before process start'
    }

    Invoke-CcodTest 'uses Hidden only for an explicit background helper' {
        $call = [pscustomobject]@{ WindowStyle = $null; Path = $null }
        $result = Start-CcodProcess -BackgroundHelper -HelperPath 'C:\Runtime\helper.exe' -HelperArguments @('--serve') -Adapters @{
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) $call.Path = $FilePath; $call.WindowStyle = $WindowStyle; [pscustomobject]@{ Pid = 500 } }.GetNewClosure()
        }
        Assert-CcodEqual 'Started' $result.Outcome 'helper starts through the same adapter boundary'
        Assert-CcodEqual 'C:\Runtime\helper.exe' $call.Path 'explicit helper path is preserved'
        Assert-CcodEqual 'Hidden' $call.WindowStyle 'background helper alone is hidden'
    }

    Invoke-CcodTest 'treats a post-recheck binding race as a failed special launch' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $candidate = New-CcodSnapshot -ProcessId 400 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002 -CommandLine $command
        $foreignOwner = New-CcodSnapshot -ProcessId 999 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -Path 'C:\Other\foreign.exe' -PackageFamilyName 'Other.Family' -Mode Unrelated -CommandLine '"C:\Other\foreign.exe"'
        $base = @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            TestLoopbackPortAvailable = { param($Port, $Address) $true }
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) [pscustomobject]@{ Id=400 } }
            ListProcessIds = { @(400) }
            GetProcess = { param($ProcessId, $StatusEvidence) if ([int]$ProcessId -eq 999) { $foreignOwner } else { $candidate } }.GetNewClosure()
            ParseCommandLine = { param($Value) @('C:\Codex\ChatGPT.exe','--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002') }
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            GetUtcNow = { [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z') }
            Delay = { param($Milliseconds) throw 'external owner is an immediate conflict' }
            GetListeningPortOwnerPids = { param($Port, $Address) @(999) }
        }
        $result = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -Adapters $base
        Assert-CcodEqual 'PortUnavailable' $result.Outcome 'tree-external listener ownership proves a post-recheck bind race'

        $missingCandidateClock = [pscustomobject]@{ Tick=0 }
        $missingCandidateAdapters = $base.Clone()
        $missingCandidateAdapters.ListProcessIds = { @() }
        $missingCandidateAdapters.GetProcess = { param($ProcessId, $StatusEvidence) if ([int]$ProcessId -eq 999) { $foreignOwner } else { $candidate } }.GetNewClosure()
        $missingCandidateAdapters.GetUtcNow = {
            $value = [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z').AddMilliseconds($missingCandidateClock.Tick * 10)
            $missingCandidateClock.Tick++
            $value
        }.GetNewClosure()
        $missingCandidate = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -StartupTimeoutMilliseconds 1 -Adapters $missingCandidateAdapters
        Assert-CcodEqual 'PortUnavailable' $missingCandidate.Outcome 'occupied endpoints conflict even when the launched candidate never materializes'

        $lag = [pscustomobject]@{ Lists=0; Tick=0; Delays=0 }
        $laggedAdapters = $base.Clone()
        $laggedAdapters.ListProcessIds = {
            $lag.Lists++
            if ($lag.Lists -eq 1) { return @() }
            @(400)
        }.GetNewClosure()
        $laggedAdapters.GetListeningPortOwnerPids = { param($Port, $Address) @(400) }
        $laggedAdapters.GetUtcNow = {
            $value = [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z').AddMilliseconds($lag.Tick)
            $lag.Tick++
            $value
        }.GetNewClosure()
        $laggedAdapters.Delay = { param($Milliseconds) $lag.Delays++ }.GetNewClosure()
        $lagged = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -StartupTimeoutMilliseconds 100 -StartupPollMilliseconds 1 -Adapters $laggedAdapters
        Assert-CcodEqual 'Started' $lagged.Outcome 'same-package owner may become a canonical candidate on the next poll'
        Assert-CcodTrue ($lag.Delays -ge 1) 'enumeration lag is condition-polled'

        $clock = [pscustomobject]@{ Tick=0; Delays=0 }
        $unconfirmedAdapters = $base.Clone()
        $unconfirmedAdapters.GetListeningPortOwnerPids = { param($Port, $Address) @() }
        $unconfirmedAdapters.GetUtcNow = {
            $value = [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z').AddMilliseconds($clock.Tick * 10)
            $clock.Tick++
            $value
        }.GetNewClosure()
        $unconfirmedAdapters.Delay = { param($Milliseconds) $clock.Delays++ }.GetNewClosure()
        $unconfirmed = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -StartupTimeoutMilliseconds 10 -StartupPollMilliseconds 5 -Adapters $unconfirmedAdapters
        Assert-CcodEqual 'StartUnconfirmed' $unconfirmed.Outcome 'deadline without endpoint ownership is not reported as Started'
    }
} catch {
    Write-Error $_
    exit 1
}
