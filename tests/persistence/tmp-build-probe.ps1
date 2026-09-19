$ErrorActionPreference='Continue'
Write-Output ("PWSH_VERSION=" + $PSVersionTable.PSVersion + " EDITION=" + $PSVersionTable.PSEdition)
$build = Join-Path (Split-Path $PSScriptRoot -Parent) 'build/build.ps1'
Write-Output ("BUILD_PATH=" + $build)
$bytes = [IO.File]::ReadAllBytes($build)
Write-Output ("BUILD_BYTES=" + $bytes.Length + " CRLF=" + ([regex]::Matches([Text.Encoding]::UTF8.GetString($bytes), "`r`n").Count) + " LF=" + ([regex]::Matches([Text.Encoding]::UTF8.GetString($bytes), "(?<!`r)`n").Count))

$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($build,[ref]$tokens,[ref]$errors)
Write-Output ("PARSE_ERRORS=" + @($errors).Count)
$defs=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object { $_.Parent -is [Management.Automation.Language.ScriptBlockAst] -and $_.Parent.Parent -is [Management.Automation.Language.NamedBlockAst] })
Write-Output ("TOP_LEVEL_FUNCTIONS=" + $defs.Count)
$names = @($defs | ForEach-Object { $_.Name })
Write-Output ("HAS_PAYLOAD=" + ($names -contains 'Copy-CcodBuildPayloadFile'))
Write-Output ("HAS_SCOPE=" + ($names -contains 'Invoke-CcodBuildTemporarySetupScope'))

# Which function contains the Copy-CcodBuildPayloadFile call sites?
$calls = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Copy-CcodBuildPayloadFile'},$true))
Write-Output ("CALL_SITES=" + $calls.Count)
foreach ($c in $calls[0..([Math]::Min(3,$calls.Count-1))]) {
    $ancestor = $c
    $chain = @()
    while ($null -ne $ancestor) {
        if ($ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) { $chain += ('FUNC:' + $ancestor.Name) }
        if ($ancestor -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $chain += 'SCRIPTBLOCK' }
        $ancestor = $ancestor.Parent
    }
    Write-Output ("CALL_LINE=" + $c.Extent.StartLineNumber + " CHAIN=" + ($chain -join ' > '))
}

# Now run the real build and capture the full failure detail.
$version = ([string]((Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'package.json') -Raw | ConvertFrom-Json).version)).Trim()
Write-Output ("ATTEMPT_VERSION=" + $version)
try { & $build -Version $version } catch {
    Write-Output ("BUILD_EXCEPTION=" + $_.Exception.GetType().FullName + ':' + $_.Exception.Message)
    Write-Output ("BUILD_POSITION=" + [string]$_.InvocationInfo.PositionMessage)
    Write-Output ("BUILD_STACK=" + ([string]$_.ScriptStackTrace).Replace("`r",' ').Replace("`n",' | '))
}
Write-Output 'PROBE_DONE'
