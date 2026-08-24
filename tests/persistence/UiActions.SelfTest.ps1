$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\UiActions.psm1'
if (-not [IO.File]::Exists($modulePath)) { throw 'MISSING_UI_ACTIONS_MODULE' }

function Assert-CcodTrue {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "ASSERT_TRUE_FAILED: $Message" }
}

function Assert-CcodEqual {
    param($Expected,$Actual,[string]$Message)
    if ($Expected -ne $Actual) { throw "ASSERT_EQUAL_FAILED: $Message expected=[$Expected] actual=[$Actual]" }
}

$module = Import-Module $modulePath -Force -PassThru
$publicFunctions = @(Get-Command -Module UiActions -CommandType Function)
Assert-CcodEqual 0 $publicFunctions.Count 'UiActions exports no tray action functions'
Assert-CcodTrue ($null -eq (Get-Command -Name Start-CcodTrayUninstall -Module UiActions -ErrorAction SilentlyContinue)) 'removed uninstall launcher is not exported'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
Assert-CcodEqual 0 @($errors).Count 'UiActions parses cleanly'
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$true) |
    ForEach-Object { $_.Name })
Assert-CcodEqual 0 @($functions | Where-Object { $_ -ceq 'Start-CcodTrayUninstall' }).Count 'uninstall launcher definition is absent'
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
Assert-CcodEqual 0 @($commands | Where-Object { $_ -ceq 'Start-CcodTrayUninstall' }).Count 'uninstall launcher call is absent'

Write-Output 'UiActions self-tests passed: 4'
