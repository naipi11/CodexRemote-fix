$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\ProductRegistration.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "ProductRegistration module is missing: $modulePath"
}
Import-Module $modulePath -Force

$runtimeId = '2.5.22-1111111111111111-22222222222222222222222222222222'
$packageSha256 = '3' * 64
$appId = '{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}'

function New-CcodRegistrationWorld {
    param([string]$InstallRoot = 'C:\fixture\CodexControlOtherDevices')

    $registration = New-CcodProductRegistration -InstallRoot $InstallRoot -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{})
    $world = [pscustomobject]@{
        Registration = $registration
        Ready = [pscustomobject][ordered]@{
            phase = 'Ready'
            runtimeId = $runtimeId
            version = '2.5.22'
            packageSha256 = $packageSha256
            bootstrapPath = $registration.bootstrapPath
            uninstallerPath = $registration.uninstallerPath
        }
        Product = $null
        Shortcuts = @{}
        WriteProductFailure = $false
        WriteShortcutFailure = $null
        ReadProductFailure = $false
        ReadShortcutFailure = $null
        Legacy = [pscustomobject]@{
            appId = $appId
            uninstallString = '"C:\legacy\unins000.exe"'
            shortcutNames = @(
                'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk',
                'Programs\Codex Control other devices\Open the tray supervisor.lnk',
                'Programs\Codex Control other devices\Compatibility check.lnk',
                'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk',
                'Programs\Codex Control other devices\CodexRemote-fix.lnk',
                'Programs\Codex Control other devices\CodexRemote-fix compatibility check.lnk',
                'Programs\Codex Control other devices\Uninstall CodexRemote-fix.lnk',
                ('Desktop\Codex ' + [char]0x8BBE + [char]0x5907 + [char]0x8FDE + [char]0x63A5 + ' (Device Connection).lnk')
            )
        }
        LegacyRemoved = $false
        LegacyRemovalCalls = 0
        Calls = [Collections.Generic.List[string]]::new()
    }
    $world | Add-Member -NotePropertyName Adapters -NotePropertyValue @{
        GetReadyProof = { param($Registration) $world.Calls.Add('Ready'); $world.Ready }.GetNewClosure()
        WriteProductRegistration = {
            param($Registration)
            $world.Calls.Add('WriteProduct')
            if ($world.WriteProductFailure) { throw 'fixture product write failed' }
            $world.Product = $Registration
        }.GetNewClosure()
        ReadProductRegistration = {
            param($Registration)
            $world.Calls.Add('ReadProduct')
            if ($world.ReadProductFailure) { throw 'fixture product read failed' }
            $world.Product
        }.GetNewClosure()
        WriteShortcut = {
            param($Kind,$Shortcut,$FileTransaction)
            $world.Calls.Add("WriteShortcut:$Kind")
            if ($world.WriteShortcutFailure -ceq $Kind) { throw 'fixture shortcut write failed' }
            $world.Shortcuts[$Kind] = $Shortcut
        }.GetNewClosure()
        ReadShortcut = {
            param($Kind,$Shortcut)
            $world.Calls.Add("ReadShortcut:$Kind")
            if ($world.ReadShortcutFailure -ceq $Kind) { throw 'fixture shortcut read failed' }
            $world.Shortcuts[$Kind]
        }.GetNewClosure()
        ReadLegacyRegistration = { param($ExpectedAppId) $world.Calls.Add('ReadLegacy'); $world.Legacy }.GetNewClosure()
        ReadVerifiedRegistration = { [pscustomobject]@{verified=($null-ne$world.Product-and$world.Shortcuts.Count-eq2)} }.GetNewClosure()
        RemoveLegacyRegistration = { param($ExpectedAppId,$ExpectedShortcutNames) $world.Calls.Add('RemoveLegacy'); $world.LegacyRemovalCalls++; $world.LegacyRemoved = $true }.GetNewClosure()
    }
    return $world
}

$results = @()

# Production mutation caught: accepting a caller-crafted path/runtime tuple as a registration contract.
$results += Invoke-CcodTest 'registration rejects noncanonical runtime version hash and install targets' {
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'relative' -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'C:\fixture\root' -RuntimeId 'runtime' -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'C:\fixture\root' -RuntimeId $runtimeId -Version '2.5.21' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'C:\fixture\root' -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 ('A' * 64) -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
}

# Production mutation caught: allowing product writes from ProtectionReady or a mismatched Ready proof.
$results += Invoke-CcodTest 'registration performs no writes before an exact Ready proof' {
    foreach ($mutation in @(
        { param($ready) $ready.phase = 'ProtectionReady' },
        { param($ready) $ready.runtimeId = '2.5.22-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
        { param($ready) $ready.version = '2.5.21' },
        { param($ready) $ready.packageSha256 = '4' * 64 },
        { param($ready) $ready.bootstrapPath = 'C:\outside\bootstrap.ps1' },
        { param($ready) $ready.uninstallerPath = 'C:\outside\uninstall.ps1' }
    )) {
        $world = New-CcodRegistrationWorld
        & $mutation $world.Ready
        Assert-CcodThrows { Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters | Out-Null } 'CCOD_PRODUCT_REGISTRATION_NOT_READY'
        Assert-CcodEqual 0 @($world.Calls | Where-Object { $_ -clike 'Write*' }).Count 'a non-Ready proof cannot reach product writes'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'a non-Ready proof cannot reach legacy removal'
    }
}

# Production mutation caught: deleting compatibility state after a partial new registration.
$results += Invoke-CcodTest 'write and read-back failures preserve every legacy entry and shortcut name' {
    foreach ($failure in @('WriteProduct','WriteStartMenu','WriteDesktop','ReadProduct','ReadStartMenu','ReadDesktop')) {
        $world = New-CcodRegistrationWorld
        switch ($failure) {
            'WriteProduct' { $world.WriteProductFailure = $true }
            'WriteStartMenu' { $world.WriteShortcutFailure = 'StartMenu' }
            'WriteDesktop' { $world.WriteShortcutFailure = 'Desktop' }
            'ReadProduct' { $world.ReadProductFailure = $true }
            'ReadStartMenu' { $world.ReadShortcutFailure = 'StartMenu' }
            'ReadDesktop' { $world.ReadShortcutFailure = 'Desktop' }
        }
        $legacyUninstallString = $world.Legacy.uninstallString
        $legacyShortcutNames = @($world.Legacy.shortcutNames)
        Assert-CcodThrows { Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters | Out-Null } 'CCOD_PRODUCT_REGISTRATION_FAILED'
        Assert-CcodEqual $legacyUninstallString $world.Legacy.uninstallString 'failure before read-back retains the legacy entry'
        Assert-CcodEqual ($legacyShortcutNames -join '|') (@($world.Legacy.shortcutNames) -join '|') 'failure before read-back retains exact legacy shortcut names'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'failed registration never removes legacy state'
    }
}

# Production mutation caught: trusting a shortcut read-back that resolves outside the selected sealed generation.
$results += Invoke-CcodTest 'shortcut path and target mismatches fail the three-record read-back gate' {
    foreach ($kind in @('StartMenu','Desktop')) {
        $world = New-CcodRegistrationWorld
        $originalRead = $world.Adapters.ReadShortcut
        $world.Adapters.ReadShortcut = {
            param($candidateKind,$expected)
            $value = & $originalRead $candidateKind $expected
            if ($candidateKind -ceq $kind) {
                $value = $value.PSObject.Copy()
                $value.bootstrapPath = 'C:\outside\bootstrap.ps1'
            }
            $value
        }.GetNewClosure()
        Assert-CcodThrows { Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters | Out-Null } 'CCOD_PRODUCT_REGISTRATION_FAILED'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'mismatched shortcut target retains legacy state'
    }
}

# Production mutation caught: considering adapter write success equivalent to durable read-back.
$results += Invoke-CcodTest 'valid Ready registration reads all three new records before exact legacy removal' {
    $world = New-CcodRegistrationWorld
    $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    Assert-CcodTrue $receipt.verified 'registration returns a verified three-record receipt'
    Assert-CcodEqual 'Ready,WriteProduct,WriteShortcut:StartMenu,WriteShortcut:Desktop,ReadProduct,ReadShortcut:StartMenu,ReadShortcut:Desktop' ($world.Calls -join ',') 'all new writes and read-backs precede legacy migration'
    Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters
    Assert-CcodEqual 1 $world.LegacyRemovalCalls 'exact legacy migration runs once after verified registration'
    Assert-CcodTrue $world.LegacyRemoved 'exact legacy registration and shortcut set is removed'
}

# Production mutation caught: accepting an unexpected AppId/name set or an unverified registration receipt.
$results += Invoke-CcodTest 'legacy migration rejects AppId and shortcut-name mismatches without deletion' {
    foreach ($mismatch in @('AppId','Shortcut','Receipt')) {
        $world = New-CcodRegistrationWorld
        $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        if ($mismatch -ceq 'AppId') { $world.Legacy.appId = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' }
        if ($mismatch -ceq 'Shortcut') { $world.Legacy.shortcutNames = @('Programs\unexpected.lnk') }
        if ($mismatch -ceq 'Receipt') { $world.Product = $null }
        Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'legacy mismatch is rejected before any deletion'
        Assert-CcodTrue (-not $world.LegacyRemoved) 'legacy state remains intact on mismatch'
    }
}

Write-Output "Product registration self-tests passed: $($results.Count)"
