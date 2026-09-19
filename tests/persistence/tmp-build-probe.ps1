$ErrorActionPreference='Continue'
Write-Output ("SHELL_VERSION=" + $PSVersionTable.PSVersion + " EDITION=" + $PSVersionTable.PSEdition)
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$build = Join-Path $repoRoot 'build\build.ps1'
Write-Output ("BUILD_PATH=" + $build + " EXISTS=" + [IO.File]::Exists($build))
if (-not [IO.File]::Exists($build)) { Write-Output 'PROBE_ABORT'; exit 0 }

# Minimal scoping pattern under this exact shell.
function Copy-CcodBuildPayloadFile { param($Source) return ('COPIED:' + $Source) }
function Invoke-CcodBuildTemporarySetupScope { param([scriptblock]$Action) & $Action }
try { Write-Output ("PATTERN=" + (Invoke-CcodBuildTemporarySetupScope -Action ({ Copy-CcodBuildPayloadFile -Source 'package.json' }))) }
catch { Write-Output ("PATTERN_FAILED=" + $_.Exception.Message) }

$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($build,[ref]$tokens,[ref]$errors)
Write-Output ("PARSE_ERRORS=" + @($errors).Count)
foreach ($e in @($errors)) { Write-Output ("PARSE_ERROR=" + $e.Message + " @line " + $e.Extent.StartLineNumber) }
$allDefs=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
Write-Output ("ALL_FUNCTION_DEFS=" + $allDefs.Count)
Write-Output ("HAS_PAYLOAD_DEF=" + [bool](@($allDefs | Where-Object { $_.Name -ceq 'Copy-CcodBuildPayloadFile' }).Count))
$calls = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Copy-CcodBuildPayloadFile'},$true))
Write-Output ("CALL_SITES=" + $calls.Count)
foreach ($c in @($calls | Select-Object -First 2)) {
    $ancestor = $c.Parent
    $chain = @()
    while ($null -ne $ancestor -and $chain.Count -lt 6) {
        if ($ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) { $chain += ('FUNC:' + $ancestor.Name) }
        elseif ($ancestor -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $chain += 'SCRIPTBLOCK' }
        elseif ($ancestor -is [Management.Automation.Language.ScriptBlockAst]) { $chain += 'SCRIPT' }
        $ancestor = $ancestor.Parent
    }
    Write-Output ("CALL_LINE=" + $c.Extent.StartLineNumber + " CHAIN=" + ($chain -join ' > '))
}

$version = ([string]((Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json).version)).Trim()
Write-Output ("ATTEMPT_VERSION=" + $version)
try { & $build -Version $version; Write-Output 'BUILD_OK' } catch {
    Write-Output ("BUILD_EXCEPTION=" + $_.Exception.GetType().FullName + ':' + $_.Exception.Message)
    Write-Output ("BUILD_POSITION=" + ([string]$_.InvocationInfo.PositionMessage).Replace("`r",' ').Replace("`n",' | '))
    Write-Output ("BUILD_STACK=" + ([string]$_.ScriptStackTrace).Replace("`r",' ').Replace("`n",' | '))
}
Write-Output 'PROBE_DONE'
