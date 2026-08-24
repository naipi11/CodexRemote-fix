Set-StrictMode -Version Latest

$script:CcodTaskName = 'Codex Control Other Devices Supervisor'
$script:CcodTaskAdapterNames = @('RegisterTask', 'UnregisterTask', 'GetTaskInfo', 'GetTaskXml', 'ResolvePrincipalToSid')

function Throw-CcodTaskError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodTaskAdapters {
    param([hashtable]$Adapters)

    $defaults = @{
        RegisterTask = {
            param($TaskName, $Definition)
            Register-ScheduledTask -TaskName $TaskName -InputObject $Definition -Force -ErrorAction Stop
        }.GetNewClosure()
        UnregisterTask = {
            param($TaskName)
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        }.GetNewClosure()
        GetTaskInfo = {
            param($TaskName)
            Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }.GetNewClosure()
        GetTaskXml = {
            param($TaskInfo)
            Export-ScheduledTask -TaskName $TaskInfo.TaskName -ErrorAction Stop
        }.GetNewClosure()
        ResolvePrincipalToSid = {
            param($UserId)
            if ($UserId -is [string] -and $UserId -cmatch '^S-1-') { return $UserId }
            try {
                return ([Security.Principal.NTAccount]::new($UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
            } catch {
                Throw-CcodTaskError 'CCOD_TASK_PRINCIPAL_INVALID' 'Task principal could not be resolved to a SID' $UserId
            }
        }.GetNewClosure()
    }

    if ($null -eq $Adapters) { return $defaults }
    if ($Adapters -isnot [hashtable]) {
        Throw-CcodTaskError 'CCOD_TASK_ADAPTER_INVALID' 'Scheduled task adapters must be a hashtable' $Adapters
    }
    $resolved = @{}
    foreach ($name in $defaults.Keys) { $resolved[$name] = $defaults[$name] }
    foreach ($key in $Adapters.Keys) {
        if ($key -isnot [string] -or $script:CcodTaskAdapterNames -cnotcontains $key -or $Adapters[$key] -isnot [scriptblock]) {
            Throw-CcodTaskError 'CCOD_TASK_ADAPTER_INVALID' 'Scheduled task adapter contract is invalid' $key
        }
        $resolved[$key] = $Adapters[$key]
    }
    return $resolved
}

function Assert-CcodTaskSpec {
    param($Spec)

    $expected = @(
        'TaskName', 'Execute', 'Argument', 'WorkingDirectory', 'LogonType', 'RunLevel', 'MultipleInstances',
        'RestartCount', 'RestartInterval', 'ExecutionTimeLimit', 'DisallowStartIfOnBatteries',
        'StopIfGoingOnBatteries', 'UserSid'
    )
    if ($null -eq $Spec -or $Spec -isnot [pscustomobject] -or
        (($Spec.PSObject.Properties.Name | Sort-Object) -join '|') -cne (($expected | Sort-Object) -join '|') -or
        $Spec.TaskName -isnot [string] -or $Spec.TaskName -cne $script:CcodTaskName -or
        $Spec.Execute -isnot [string] -or -not [IO.Path]::IsPathRooted($Spec.Execute) -or
        $Spec.Argument -isnot [string] -or [string]::IsNullOrWhiteSpace($Spec.Argument) -or
        $Spec.WorkingDirectory -isnot [string] -or -not [IO.Path]::IsPathRooted($Spec.WorkingDirectory) -or
        $Spec.UserSid -isnot [string] -or $Spec.UserSid -cnotmatch '^S-1-(?:\d+-){1,14}\d+$' -or
        $Spec.LogonType -cne 'Interactive' -or $Spec.RunLevel -cne 'Limited' -or
        $Spec.MultipleInstances -cne 'IgnoreNew' -or
        $Spec.RestartCount -isnot [int] -or $Spec.RestartCount -ne 3 -or
        $Spec.RestartInterval -cne 'PT1M' -or $Spec.ExecutionTimeLimit -cne 'PT0S' -or
        $Spec.DisallowStartIfOnBatteries -isnot [bool] -or $Spec.StopIfGoingOnBatteries -isnot [bool]) {
        Throw-CcodTaskError 'CCOD_TASK_SPEC_INVALID' 'Supervisor task spec is invalid' $Spec
    }
    return $Spec
}

function Get-CcodSupervisorTaskSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$UserSid
    )

    if ([string]::IsNullOrWhiteSpace($InstallRoot) -or -not [IO.Path]::IsPathRooted($InstallRoot) -or
        $UserSid -isnot [string] -or $UserSid -cnotmatch '^S-1-(?:\d+-){1,14}\d+$') {
        Throw-CcodTaskError 'CCOD_TASK_SPEC_INVALID' 'InstallRoot must be absolute and UserSid must be a canonical SID' $InstallRoot
    }
    $canonicalRoot = [IO.Path]::GetFullPath($InstallRoot)
    $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $canonicalRoot 'bootstrap.ps1'))
    $execute = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $argument = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $bootstrapPath + '" -InstallRoot "' + $canonicalRoot + '" -EntryMode Task'

    return [pscustomobject][ordered]@{
        TaskName = $script:CcodTaskName
        Execute = $execute
        Argument = $argument
        WorkingDirectory = $canonicalRoot
        LogonType = 'Interactive'
        RunLevel = 'Limited'
        MultipleInstances = 'IgnoreNew'
        RestartCount = 3
        RestartInterval = 'PT1M'
        ExecutionTimeLimit = 'PT0S'
        DisallowStartIfOnBatteries = $false
        StopIfGoingOnBatteries = $false
        UserSid = $UserSid
    }
}

function New-CcodSupervisorTaskDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Spec)

    $validated = Assert-CcodTaskSpec -Spec $Spec
    $action = New-ScheduledTaskAction -Execute $validated.Execute -Argument $validated.Argument -WorkingDirectory $validated.WorkingDirectory
    $principal = New-ScheduledTaskPrincipal -UserId $validated.UserSid -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $validated.UserSid
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    return New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings
}

function Install-CcodSupervisorTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$TaskName,
        [hashtable]$Adapters
    )

    if ($PSCmdlet.ShouldProcess($TaskName, 'Register the limited current-user Codex Control Other Devices supervisor logon task')) {
        $adapters = Get-CcodTaskAdapters -Adapters $Adapters
        & $adapters.RegisterTask $TaskName $Definition
    }
}

function Remove-CcodSupervisorTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [hashtable]$Adapters
    )

    if ($PSCmdlet.ShouldProcess($TaskName, 'Remove the Codex Control Other Devices supervisor logon task')) {
        $adapters = Get-CcodTaskAdapters -Adapters $Adapters
        & $adapters.UnregisterTask $TaskName
    }
}

function ConvertTo-CcodTaskRunLevel {
    param([Parameter(Mandatory)][string]$Value)

    switch ($Value) {
        'LeastPrivilege' { return 'Limited' }
        'HighestAvailable' { return 'Highest' }
        default { return $Value }
    }
}

function ConvertTo-CcodTaskBoolean {
    param([Parameter(Mandatory)][string]$Value)

    try {
        return [bool]::Parse($Value)
    } catch {
        Throw-CcodTaskError 'CCOD_TASK_SNAPSHOT_INVALID' 'Exported task XML contains an invalid boolean' $Value
    }
}

function Get-CcodSupervisorTaskSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodTaskAdapters -Adapters $Adapters
    $info = & $adapters.GetTaskInfo $TaskName
    $xmlText = & $adapters.GetTaskXml $info
    $xml = $null
    try {
        $xml = [xml]$xmlText
    } catch {
        Throw-CcodTaskError 'CCOD_TASK_SNAPSHOT_INVALID' 'Exported task XML could not be parsed' $TaskName
    }

    $principalNode = $xml.Task.Principals.Principal
    $settingsNode = $xml.Task.Settings
    $actionNode = $xml.Task.Actions.Exec
    if ($null -eq $principalNode -or $null -eq $settingsNode -or $null -eq $actionNode -or
        $null -eq $settingsNode.RestartOnFailure -or
        [string]::IsNullOrWhiteSpace([string]$principalNode.UserId) -or
        [string]::IsNullOrWhiteSpace([string]$principalNode.LogonType) -or
        [string]::IsNullOrWhiteSpace([string]$principalNode.RunLevel) -or
        [string]::IsNullOrWhiteSpace([string]$settingsNode.MultipleInstancesPolicy) -or
        [string]::IsNullOrWhiteSpace([string]$settingsNode.ExecutionTimeLimit) -or
        [string]::IsNullOrWhiteSpace([string]$settingsNode.DisallowStartIfOnBatteries) -or
        [string]::IsNullOrWhiteSpace([string]$settingsNode.StopIfGoingOnBatteries) -or
        [string]::IsNullOrWhiteSpace([string]$actionNode.Command)) {
        Throw-CcodTaskError 'CCOD_TASK_SNAPSHOT_INVALID' 'Exported task XML is missing required safety fields' $TaskName
    }

    $principalSid = & $adapters.ResolvePrincipalToSid ([string]$principalNode.UserId)
    $restartCount = 0
    try {
        $restartCount = [int][string]$settingsNode.RestartOnFailure.Count
    } catch {
        Throw-CcodTaskError 'CCOD_TASK_SNAPSHOT_INVALID' 'Exported task XML has an invalid restart count' $TaskName
    }

    return [pscustomobject][ordered]@{
        TaskName = [string]$info.TaskName
        TaskPath = [string]$info.TaskPath
        State = [string]$info.State
        PrincipalSid = [string]$principalSid
        LogonType = [string]$principalNode.LogonType
        RunLevel = ConvertTo-CcodTaskRunLevel -Value ([string]$principalNode.RunLevel)
        MultipleInstances = [string]$settingsNode.MultipleInstancesPolicy
        RestartCount = $restartCount
        RestartInterval = [string]$settingsNode.RestartOnFailure.Interval
        ExecutionTimeLimit = [string]$settingsNode.ExecutionTimeLimit
        DisallowStartIfOnBatteries = ConvertTo-CcodTaskBoolean -Value ([string]$settingsNode.DisallowStartIfOnBatteries)
        StopIfGoingOnBatteries = ConvertTo-CcodTaskBoolean -Value ([string]$settingsNode.StopIfGoingOnBatteries)
        Execute = [IO.Path]::GetFullPath([string]$actionNode.Command)
        Argument = [string]$actionNode.Arguments
        WorkingDirectory = [string]$actionNode.WorkingDirectory
    }
}

Export-ModuleMember -Function Get-CcodSupervisorTaskSpec, New-CcodSupervisorTaskDefinition, Install-CcodSupervisorTask, Get-CcodSupervisorTaskSnapshot, Remove-CcodSupervisorTask
