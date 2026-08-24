$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\ScheduledTask.psm1'
Import-Module $modulePath -Force

$script:CcodSyntheticSid = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
$script:CcodCurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Assert-CcodExactEqual($Expected, $Actual, [string]$Message) {
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "ASSERT_EXACT: $Message expected=[$Expected] actual=[$Actual]"
    }
}

function New-CcodFakeTaskAdapters {
    $state = [ordered]@{
        RegisterCalls = 0
        RegisteredName = $null
        UnregisterCalls = 0
        UnregisteredName = $null
        SnapshotCalls = 0
    }
    $adapters = @{
        RegisterTask = {
            param($TaskName, $Definition)
            $state.RegisterCalls++
            $state.RegisteredName = $TaskName
        }.GetNewClosure()
        UnregisterTask = {
            param($TaskName)
            $state.UnregisterCalls++
            $state.UnregisteredName = $TaskName
        }.GetNewClosure()
        GetTaskInfo = {
            param($TaskName)
            $state.SnapshotCalls++
            [pscustomobject]@{
                TaskName = $TaskName
                TaskPath = '\'
                State = 'Ready'
                Principal = [pscustomobject]@{ UserId = 'S-1-5-21-test' }
            }
        }.GetNewClosure()
        GetTaskXml = {
            param($TaskInfo)
            @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Date>2026-08-04T00:00:00</Date><Author>CodexControlOtherDevices</Author></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>S-1-5-21-test</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel><UserId>S-1-5-21-test</UserId></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec>
    <Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
    <Arguments>-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\Users\name\AppData\Local\CodexControlOtherDevices\bootstrap.ps1" -InstallRoot "C:\Users\name\AppData\Local\CodexControlOtherDevices" -EntryMode Task</Arguments>
    <WorkingDirectory>C:\Users\name\AppData\Local\CodexControlOtherDevices</WorkingDirectory>
  </Exec></Actions>
</Task>
'@
        }.GetNewClosure()
        ResolvePrincipalToSid = {
            param($UserId)
            if ($UserId -cmatch '^S-1-') { return $UserId }
            return ([Security.Principal.NTAccount]::new($UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
        }.GetNewClosure()
    }
    return [pscustomobject]@{ State = $state; Adapters = $adapters }
}

$results = @()

$results += Invoke-CcodTest 'supervisor task spec uses the fixed limited interactive contract' {
    $spec = Get-CcodSupervisorTaskSpec -InstallRoot 'C:\Users\name\AppData\Local\CodexControlOtherDevices' -UserSid $script:CcodSyntheticSid
    Assert-CcodExactEqual 'Codex Control Other Devices Supervisor' $spec.TaskName 'fixed task name'
    Assert-CcodExactEqual 'Interactive' $spec.LogonType 'maps to InteractiveToken XML'
    Assert-CcodExactEqual 'Limited' $spec.RunLevel 'no elevation'
    Assert-CcodExactEqual 'IgnoreNew' $spec.MultipleInstances 'single task instance'
    Assert-CcodExactEqual 3 $spec.RestartCount 'bounded retries'
    Assert-CcodExactEqual 'PT1M' $spec.RestartInterval 'one minute'
    Assert-CcodExactEqual 'PT0S' $spec.ExecutionTimeLimit 'no 72-hour limit'
    Assert-CcodTrue ($spec.Argument -match '-WindowStyle Hidden') 'background console hidden'
    Assert-CcodTrue ([IO.Path]::IsPathRooted($spec.Execute)) 'absolute PowerShell path'
    Assert-CcodTrue ($spec.Argument -match ([Regex]::Escape('bootstrap.ps1'))) 'bootstrap is the task target'
    Assert-CcodTrue ($spec.Argument -match ([Regex]::Escape('-InstallRoot "C:\Users\name\AppData\Local\CodexControlOtherDevices"'))) 'task passes absolute InstallRoot'
    Assert-CcodTrue ($spec.Argument -match ([Regex]::Escape('-EntryMode Task'))) 'scheduled task explicitly enters bootstrap Task mode'
    Assert-CcodTrue ([IO.Path]::IsPathRooted($spec.WorkingDirectory)) 'working directory is absolute'
}

$results += Invoke-CcodTest 'task definition maps every exact safety setting' {
    $spec = Get-CcodSupervisorTaskSpec -InstallRoot 'C:\Users\name\AppData\Local\CodexControlOtherDevices' -UserSid $script:CcodCurrentUserSid
    $definition = New-CcodSupervisorTaskDefinition -Spec $spec
    Assert-CcodExactEqual 'Interactive' ([string]$definition.Principal.LogonType) 'principal is interactive'
    Assert-CcodExactEqual 'Limited' ([string]$definition.Principal.RunLevel) 'principal is limited'
    Assert-CcodExactEqual 'IgnoreNew' ([string]$definition.Settings.MultipleInstances) 'ignore new instances'
    Assert-CcodExactEqual 3 ([int]$definition.Settings.RestartCount) 'restart count is three'
    Assert-CcodExactEqual 'PT1M' ([string]$definition.Settings.RestartInterval) 'restart interval is one minute'
    Assert-CcodExactEqual 'PT0S' ([string]$definition.Settings.ExecutionTimeLimit) 'no execution limit'
    Assert-CcodExactEqual $false ([bool]$definition.Settings.DisallowStartIfOnBatteries) 'battery start allowed'
    Assert-CcodExactEqual $false ([bool]$definition.Settings.StopIfGoingOnBatteries) 'battery switch does not stop'
    Assert-CcodExactEqual ([IO.Path]::GetFullPath($spec.Execute)) ([IO.Path]::GetFullPath($definition.Actions[0].Execute)) 'absolute PowerShell action'
    Assert-CcodTrue ($definition.Actions[0].Arguments -match '-WindowStyle Hidden') 'hidden action argument'
    Assert-CcodTrue ($definition.Actions[0].WorkingDirectory -eq $spec.WorkingDirectory) 'install root working directory'
    Assert-CcodTrue (@($definition.Triggers).Count -ge 1) 'at least one trigger'
}

$results += Invoke-CcodTest 'install and remove honor ShouldProcess and call exact adapters' {
    $fake = New-CcodFakeTaskAdapters
    $spec = Get-CcodSupervisorTaskSpec -InstallRoot 'C:\Users\name\AppData\Local\CodexControlOtherDevices' -UserSid $script:CcodCurrentUserSid
    $definition = New-CcodSupervisorTaskDefinition -Spec $spec

    Install-CcodSupervisorTask -Definition $definition -TaskName $spec.TaskName -Adapters $fake.Adapters
    Assert-CcodExactEqual 1 $fake.State.RegisterCalls 'real install registers once'
    Assert-CcodExactEqual $spec.TaskName $fake.State.RegisteredName 'fixed task name is registered'

    Install-CcodSupervisorTask -Definition $definition -TaskName $spec.TaskName -Adapters $fake.Adapters -WhatIf
    Assert-CcodExactEqual 1 $fake.State.RegisterCalls 'WhatIf never registers'

    Remove-CcodSupervisorTask -TaskName $spec.TaskName -Adapters $fake.Adapters
    Assert-CcodExactEqual 1 $fake.State.UnregisterCalls 'real remove unregisters once'
    Assert-CcodExactEqual $spec.TaskName $fake.State.UnregisteredName 'fixed task name is removed'

    Remove-CcodSupervisorTask -TaskName $spec.TaskName -Adapters $fake.Adapters -WhatIf
    Assert-CcodExactEqual 1 $fake.State.UnregisterCalls 'WhatIf never unregisters'
}

$results += Invoke-CcodTest 'snapshot verifies exported XML safety values and resolves the principal SID' {
    $fake = New-CcodFakeTaskAdapters
    $snapshot = Get-CcodSupervisorTaskSnapshot -TaskName 'Codex Control Other Devices Supervisor' -Adapters $fake.Adapters
    Assert-CcodExactEqual 1 $fake.State.SnapshotCalls 'snapshot reads registered task once'
    Assert-CcodExactEqual 'S-1-5-21-test' $snapshot.PrincipalSid 'registered principal resolves to SID'
    Assert-CcodExactEqual 'InteractiveToken' $snapshot.LogonType 'XML logon type is interactive token'
    Assert-CcodExactEqual 'Limited' $snapshot.RunLevel 'XML least privilege maps to limited'
    Assert-CcodExactEqual 'IgnoreNew' $snapshot.MultipleInstances 'XML ignores new instances'
    Assert-CcodExactEqual 3 $snapshot.RestartCount 'XML restart count'
    Assert-CcodExactEqual 'PT1M' $snapshot.RestartInterval 'XML restart interval'
    Assert-CcodExactEqual 'PT0S' $snapshot.ExecutionTimeLimit 'XML has no execution limit'
    Assert-CcodExactEqual $false $snapshot.DisallowStartIfOnBatteries 'XML allows battery start'
    Assert-CcodExactEqual $false $snapshot.StopIfGoingOnBatteries 'XML does not stop on battery'
    Assert-CcodTrue ([IO.Path]::IsPathRooted($snapshot.Execute)) 'XML action is absolute'
    Assert-CcodTrue ($snapshot.Argument -match '-WindowStyle Hidden') 'XML action is hidden'
    Assert-CcodTrue ($snapshot.Argument -match ([Regex]::Escape('-EntryMode Task'))) 'XML action preserves bootstrap Task mode'
}

$results | Format-Table -AutoSize
Write-Host ("Scheduled task self-test passed: {0}" -f $results.Count)
