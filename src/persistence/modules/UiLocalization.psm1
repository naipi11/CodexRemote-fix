Set-StrictMode -Version Latest

$script:CcodUiModes=@('System','zh-CN','en-US')
$script:CcodUiKeys=@(
  'Tray.Title',
  'Connection.WaitingForCodex','Connection.Checking','Connection.Connected','Connection.RepairNeeded','Connection.Error',
  'Protection.Running','Protection.Reconnecting','Protection.Stopping',
  'Menu.CheckAndRepair','Menu.Language','Menu.FollowSystem','Menu.Chinese','Menu.English','Menu.OpenLogs','Menu.About','Menu.AboutVersion','Menu.Exit',
  'Dialog.ExitTitle','Dialog.ExitMessage','Error.ActionFailed','Error.LanguageChange'
)
$script:CcodUiEmergencyEnglish=[ordered]@{
  'Tray.Title'='CodexRemote-fix'
  'Connection.WaitingForCodex'='Connection: Waiting for Codex'
  'Connection.Checking'='Connection: Checking'
  'Connection.Connected'='Connection: Connected'
  'Connection.RepairNeeded'='Connection: Repair needed'
  'Connection.Error'='Connection: Error'
  'Protection.Running'='Protection: Running'
  'Protection.Reconnecting'='Protection: Reconnecting'
  'Protection.Stopping'='Protection: Stopping'
  'Menu.CheckAndRepair'='Check and repair remote connection'
  'Menu.Language'=('Language / '+[char]0x8bed+[char]0x8a00)
  'Menu.FollowSystem'='Follow system ({0})'
  'Menu.Chinese'=([char]0x4e2d+[char]0x6587)
  'Menu.English'='English'
  'Menu.OpenLogs'='Open logs'
  'Menu.About'='About'
  'Menu.AboutVersion'='CodexRemote-fix | Version {0}'
  'Menu.Exit'='Exit'
  'Dialog.ExitTitle'='Exit CodexRemote-fix?'
  'Dialog.ExitMessage'='Remote control will stop and Codex may restart in normal mode before CodexRemote-fix exits.'
  'Error.ActionFailed'='The requested action could not be completed.'
  'Error.LanguageChange'='Could not change language. The previous language remains active.'
}

function Throw-CcodUiError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$null)
}

function Resolve-CcodUiLocale {
  param([string]$LanguageMode,[string]$SystemCultureName)
  if($script:CcodUiModes -cnotcontains $LanguageMode){Throw-CcodUiError 'CCOD_UI_LANGUAGE_INVALID' 'The UI language mode is invalid.'}
  if($LanguageMode -cne 'System'){return $LanguageMode}
  if($SystemCultureName -is [string] -and $SystemCultureName -cmatch '^zh(?:-|$)'){return 'zh-CN'}
  return 'en-US'
}

function Test-CcodUiProperties {
    param($Value,[string[]]$Names)
    if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
    $actual=@($Value.PSObject.Properties.Name)
    if($actual.Count -ne $Names.Count){return $false}
    for($i=0;$i -lt $Names.Count;$i++){
        $property=$Value.PSObject.Properties[$actual[$i]]
        if($actual[$i] -cne $Names[$i] -or $property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){return $false}
    }
    return $true
}

function Test-CcodUiText {
    param($Value)
    if($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 300){return $false}
    foreach($character in $Value.ToCharArray()){if([char]::IsControl($character)){return $false}}
    return $true
}

function Test-CcodUiJsonHasNoDuplicateProperties {
    param([string]$Json)
    $objects=[Collections.Generic.Stack[hashtable]]::new()
    for($index=0;$index -lt $Json.Length;$index++){
        $character=$Json[$index]
        if($character -eq '{'){$objects.Push(@{});continue}
        if($character -eq '}'){if($objects.Count -eq 0){return $false};$objects.Pop();continue}
        if($character -ne '"'){continue}
        $index++;$value=''
        while($index -lt $Json.Length){
            $character=$Json[$index]
            if($character -eq '"'){break}
            if($character -ne [char]92){$value+=$character;$index++;continue}
            $index++;if($index -ge $Json.Length){return $false};$escape=$Json[$index]
            if($escape -eq 'u'){
                if($index+4 -ge $Json.Length){return $false}
                try{$value+=[char][Convert]::ToInt32($Json.Substring($index+1,4),16)}catch{return $false}
                $index+=5;continue
            }
            switch([string]$escape){
                '"' {$decoded='"'}
                '\\' {$decoded=[char]92}
                '/' {$decoded='/'}
                'b' {$decoded=[char]8}
                'f' {$decoded=[char]12}
                'n' {$decoded=[char]10}
                'r' {$decoded=[char]13}
                't' {$decoded=[char]9}
                default {return $false}
            }
            $value+=$decoded;$index++
        }
        if($index -ge $Json.Length){return $false}
        $next=$index+1;while($next -lt $Json.Length -and [char]::IsWhiteSpace($Json[$next])){$next++}
        if($next -lt $Json.Length -and $Json[$next] -eq ':'){
            if($objects.Count -eq 0 -or $objects.Peek().ContainsKey($value)){return $false}
            $objects.Peek().Add($value,$true)
        }
        continue
    }
    return $objects.Count -eq 0
}

function Get-CcodUiResourcePath {
    param([string]$ResourcesRoot,[string]$Locale)
    if([string]::IsNullOrWhiteSpace($ResourcesRoot) -or -not [IO.Path]::IsPathRooted($ResourcesRoot)){return $null}
    try{
        $root=[IO.Path]::GetFullPath($ResourcesRoot)
        $rootItem=Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if(-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){return $null}
        $path=[IO.Path]::GetFullPath((Join-Path $root ('ui.'+$Locale+'.json')))
        $prefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path)){return $null}
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){return $null}
        return $path
    }catch{return $null}
}

function Read-CcodUiCatalogResource {
    param([string]$ResourcesRoot,[string]$Locale)
    $path=Get-CcodUiResourcePath $ResourcesRoot $Locale
    if($null -eq $path){return $null}
    try{
        $bytes=[IO.File]::ReadAllBytes($path)
        if($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf){return $null}
        $json=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false))
        foreach($character in $json.ToCharArray()){if([char]::IsControl($character) -and $character -ne [char]10 -and $character -ne [char]13 -and $character -ne [char]9){return $null}}
        if(-not (Test-CcodUiJsonHasNoDuplicateProperties $json)){return $null}
        $catalog=$json|ConvertFrom-Json -ErrorAction Stop
        if(-not (Test-CcodUiProperties $catalog @('schemaVersion','locale','strings'))){return $null}
        if($catalog.schemaVersion -isnot [int] -and $catalog.schemaVersion -isnot [long]){return $null}
        if($catalog.schemaVersion -ne 1 -or $catalog.locale -isnot [string] -or $catalog.locale -cne $Locale -or -not (Test-CcodUiProperties $catalog.strings $script:CcodUiKeys)){return $null}
        foreach($key in $script:CcodUiKeys){if(-not (Test-CcodUiText $catalog.strings.PSObject.Properties[$key].Value)){return $null}}
        return [pscustomobject]$catalog.strings
    }catch{return $null}
}

function New-CcodUiCatalog {
    param([string]$LanguageMode,[string]$EffectiveLocale,$Strings,[bool]$UsedEmergencyCatalog,[AllowNull()][string]$ErrorCode)
    return [pscustomobject][ordered]@{LanguageMode=$LanguageMode;EffectiveLocale=$EffectiveLocale;Strings=$Strings;UsedEmergencyCatalog=$UsedEmergencyCatalog;ErrorCode=$ErrorCode}
}

function Get-CcodUiCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourcesRoot,[Parameter(Mandatory)][string]$LanguageMode,[AllowNull()][string]$SystemCultureName)
    $effective=Resolve-CcodUiLocale $LanguageMode $SystemCultureName
    $selected=Read-CcodUiCatalogResource $ResourcesRoot $effective
    if($null -ne $selected){return New-CcodUiCatalog $LanguageMode $effective $selected $false $null}
    if($effective -cne 'en-US'){
        $english=Read-CcodUiCatalogResource $ResourcesRoot 'en-US'
        if($null -ne $english){return New-CcodUiCatalog $LanguageMode 'en-US' $english $false 'CCOD_UI_RESOURCE_INVALID'}
    }
    return New-CcodUiCatalog $LanguageMode 'en-US' ([pscustomobject]$script:CcodUiEmergencyEnglish) $true 'CCOD_UI_RESOURCE_INVALID'
}

function Get-CcodUiString {
  [CmdletBinding()]param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$Key,[object[]]$Arguments=@())
  if($null -eq $Catalog -or $null -eq $Catalog.Strings -or $script:CcodUiKeys -cnotcontains $Key){Throw-CcodUiError 'CCOD_UI_STRING_INVALID' 'The UI string request is invalid.'}
  $property=$Catalog.Strings.PSObject.Properties[$Key]
  if($null -eq $property -or $property.Value -isnot [string]){Throw-CcodUiError 'CCOD_UI_STRING_INVALID' 'The UI string request is invalid.'}
  try{$value=if($Arguments.Count -eq 0){$property.Value}else{[string]::Format([Globalization.CultureInfo]::InvariantCulture,$property.Value,$Arguments)}}catch{Throw-CcodUiError 'CCOD_UI_STRING_INVALID' 'The UI string request is invalid.'}
  if(-not (Test-CcodUiText $value)){Throw-CcodUiError 'CCOD_UI_STRING_INVALID' 'The UI string request is invalid.'}
  return $value
}

Export-ModuleMember -Function Get-CcodUiCatalog,Get-CcodUiString
