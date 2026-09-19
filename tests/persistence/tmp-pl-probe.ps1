$ErrorActionPreference='Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $repo
Write-Output ("PS=" + $PSVersionTable.PSVersion + ' ' + $PSVersionTable.PSEdition)
Import-Module (Join-Path $repo 'build\TrayHostBuild.psm1') -Force
$version = ([string]((Get-Content (Join-Path $repo 'package.json') -Raw | ConvertFrom-Json).version)).Trim()
$commit = ([string](& git -C $repo rev-parse HEAD)).Trim().ToLowerInvariant()
$stamp = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
$out = Join-Path $env:TEMP ('ccod-pl-probe-' + [guid]::NewGuid().ToString('N'))
try {
    $r = Invoke-CcodPortableLauncherBuild -RepositoryRoot $repo -Version $version -OutputDirectory $out -GitCommit $commit -BuildTimestampUtc $stamp
    Write-Output ('PL_BUILD_OK=' + [string]$r.Sha256)
} catch {
    Write-Output ('PL_BUILD_FAIL=' + $_.Exception.Message)
    Write-Output ('PL_BUILD_STACK=' + ([string]$_.ScriptStackTrace).Replace("`r",' ').Replace("`n",' | '))
}
$p = Join-Path $out 'portable-launcher-provenance.json'
if (Test-Path -LiteralPath $p) {
    $raw = Get-Content -LiteralPath $p -Raw
    Write-Output ('PROV_RAW=' + $raw.Replace("`r",' ').Replace("`n",' '))
    $obj = $raw | ConvertFrom-Json
    Write-Output ('PROV_COMPILER_NAME=[' + [string]$obj.compiler.name + '] TYPE=' + $obj.compiler.name.GetType().FullName)
    Write-Output ('PROV_COMPILER_SHA=[' + [string]$obj.compiler.sha256 + '] LEN=' + ([string]$obj.compiler.sha256).Length + ' TYPE=' + $obj.compiler.sha256.GetType().FullName)
    Write-Output ('PROV_COMMIT=[' + [string]$obj.gitCommit + '] ISSTR=' + ($obj.gitCommit -is [string]))
    Write-Output ('PROV_TS=[' + [string]$obj.buildTimestampUtc + '] ISSTR=' + ($obj.buildTimestampUtc -is [string]))
} else { Write-Output 'PROV_MISSING' }
try {
    Test-CcodPortableLauncherArtifact -RepositoryRoot $repo -Version $version -ArtifactDirectory $out -ExpectedGitCommit $commit | Out-Null
    Write-Output 'PL_TEST_OK'
} catch {
    Write-Output ('PL_TEST_FAIL=' + $_.Exception.Message)
    Write-Output ('PL_TEST_STACK=' + ([string]$_.ScriptStackTrace).Replace("`r",' ').Replace("`n",' | '))
}
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output 'PROBE_DONE'
