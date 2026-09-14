Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1')

$script:CcodUiLanguageModes = @('System', 'zh-CN', 'en-US')

function Throw-CcodUiPreferenceError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $TargetObject
    )

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $TargetObject
    )
}

function Get-CcodUiPreferenceAdapters {
    param([hashtable]$Overrides)

    $resolved = @{ UtcNow = { [datetimeoffset]::UtcNow } }
    if ($null -ne $Overrides) {
        foreach ($name in $Overrides.Keys) {
            if ($resolved.Keys -cnotcontains $name) { throw "Unknown adapter: $name" }
            $resolved[$name] = $Overrides[$name]
        }
    }
    return $resolved
}

function Get-CcodUiPreferencePropertyNames {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-CcodUiPreferenceStore {
    param([Parameter(Mandatory)]$Store)

    if ($Store -isnot [pscustomobject] -and $Store -isnot [Collections.IDictionary]) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences must be an object.' $Store
    }

    $expectedNames = @('schemaVersion', 'languageMode', 'updatedAtUtc')
    $actualNames = @(Get-CcodUiPreferencePropertyNames -Value $Store)
    if ($actualNames.Count -ne $expectedNames.Count) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences have unexpected or missing fields.' $Store
    }
    for ($index = 0; $index -lt $expectedNames.Count; $index++) {
        if ($actualNames[$index] -cne $expectedNames[$index]) {
            Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences fields are not in the required order.' $Store
        }
    }

    if (($Store.schemaVersion -isnot [int] -and $Store.schemaVersion -isnot [long]) -or $Store.schemaVersion -ne 1) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences schemaVersion must be integer 1.' $Store
    }
    if ($Store.languageMode -isnot [string] -or $script:CcodUiLanguageModes -cnotcontains $Store.languageMode) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences languageMode is invalid.' $Store
    }
    if ($Store.updatedAtUtc -isnot [string]) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences updatedAtUtc must be canonical UTC.' $Store
    }

    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParseExact($Store.updatedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -or
        $parsed.Offset -ne [timespan]::Zero -or
        $parsed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -cne $Store.updatedAtUtc) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_INVALID' 'UI preferences updatedAtUtc must be canonical UTC.' $Store
    }
}

function New-CcodUiPreferenceStore {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LanguageMode,
        [Parameter(Mandatory)][string]$UpdatedAtUtc
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        languageMode = $LanguageMode
        updatedAtUtc = $UpdatedAtUtc
    }
}

function Get-CcodUiPreferenceTimestamp {
    param([Parameter(Mandatory)][hashtable]$Adapters)

    $now = & $Adapters.UtcNow
    if ($now -isnot [datetimeoffset]) {
        Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_CLOCK_INVALID' 'UI preferences clock must return a DateTimeOffset value.' $now
    }
    return $now.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Initialize-CcodUiPreference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[switch]$AllowExisting)

    $path = Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'ui-preferences.json' -AllowMissingLeaf
    if([IO.File]::Exists($path)){
        if(-not$AllowExisting){Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_EXISTS' 'UI preferences already exist.' $path}
        $existing=Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'UI preferences';Assert-CcodUiPreferenceStore -Store $existing
        return $existing
    }
    $store = New-CcodUiPreferenceStore -LanguageMode 'System' -UpdatedAtUtc (Get-CcodUiPreferenceTimestamp -Adapters (Get-CcodUiPreferenceAdapters))
    Assert-CcodUiPreferenceStore -Store $store
    try {
        Write-CcodAtomicJsonIfAbsent -Path $path -Value $store
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ATOMIC_TARGET_EXISTS*') {
            Throw-CcodUiPreferenceError 'CCOD_UI_PREFERENCES_EXISTS' 'UI preferences already exist.' $path
        }
        throw
    }
    return $store
}

function Read-CcodUiPreference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    $path = Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'ui-preferences.json' -AllowMissingLeaf
    if (-not [IO.File]::Exists($path)) {
        return [pscustomobject][ordered]@{ LanguageMode = 'System'; FallbackUsed = $true; ErrorCode = 'CCOD_UI_PREFERENCES_MISSING' }
    }
    try {
        $store = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'UI preferences'
        Assert-CcodUiPreferenceStore -Store $store
        return [pscustomobject][ordered]@{ LanguageMode = $store.languageMode; FallbackUsed = $false; ErrorCode = $null }
    } catch {
        return [pscustomobject][ordered]@{ LanguageMode = 'System'; FallbackUsed = $true; ErrorCode = 'CCOD_UI_PREFERENCES_INVALID' }
    }
}

function Set-CcodUiLanguageMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LanguageMode,
        [hashtable]$Adapters
    )

    if ($script:CcodUiLanguageModes -cnotcontains $LanguageMode) {
        Throw-CcodUiPreferenceError 'CCOD_UI_LANGUAGE_INVALID' 'The UI language mode is invalid.' $null
    }
    $resolved = Get-CcodUiPreferenceAdapters -Overrides $Adapters
    $updatedAtUtc = Get-CcodUiPreferenceTimestamp -Adapters $resolved
    $store = New-CcodUiPreferenceStore -LanguageMode $LanguageMode -UpdatedAtUtc $updatedAtUtc
    Assert-CcodUiPreferenceStore -Store $store
    $path = Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'ui-preferences.json' -AllowMissingLeaf
    Write-CcodAtomicJson -Path $path -Value $store
    return [pscustomobject][ordered]@{ LanguageMode = $LanguageMode; UpdatedAtUtc = $updatedAtUtc }
}

Export-ModuleMember -Function Initialize-CcodUiPreference, Read-CcodUiPreference, Set-CcodUiLanguageMode
