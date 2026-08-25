[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$TransactionId,
    [Parameter(Mandatory)][string]$InstallerRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Throw-CcodPortableFinalizerError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodPortableFinalizerFullPath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_PATH_INVALID' "$Kind must be an absolute path" $Path
    }
    try { return [IO.Path]::GetFullPath($Path) }
    catch { Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_PATH_INVALID' "$Kind is not a valid path" $Path }
}

function Assert-CcodPortableFinalizerRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full = Get-CcodPortableFinalizerFullPath -Path $Path -Kind $Kind
    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch { Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_PATH_INVALID' "$Kind is missing or inaccessible" $full }
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_PATH_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    return $full
}

$parsedTransactionId = [guid]::Empty
if (-not [guid]::TryParseExact($TransactionId,'D',[ref]$parsedTransactionId) -or $parsedTransactionId.ToString('D') -cne $TransactionId) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_TRANSACTION_INVALID' 'The portable uninstall transaction ID is not canonical.' $TransactionId
}
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_PATH_INVALID' 'Local application data is unavailable.' $localAppData
}
$localAppData = [IO.Path]::GetFullPath($localAppData)
$expectedInstallerRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexControlOtherDevices-installer'))
$expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexControlOtherDevices'))
$providedInstallerRoot = Get-CcodPortableFinalizerFullPath -Path $InstallerRoot -Kind 'Portable installer root'
$providedInstallRoot = Get-CcodPortableFinalizerFullPath -Path $InstallRoot -Kind 'Protected install root'
if ($providedInstallerRoot -cne $expectedInstallerRoot -or $providedInstallRoot -cne $expectedInstallRoot) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_PATH_INVALID' 'The portable finalizer was not given the exact current-user product roots.' $PSBoundParameters
}

$transactionRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexRemote-fix-uninstall'))
$transactionDirectory = [IO.Path]::GetFullPath((Join-Path $transactionRoot $TransactionId))
$payloadRoot = [IO.Path]::GetFullPath((Join-Path $transactionDirectory 'payload'))
$expectedFinalizer = [IO.Path]::GetFullPath((Join-Path $payloadRoot 'src\persistence\PortableUninstallFinalizer.ps1'))
if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or (Get-CcodPortableFinalizerFullPath -Path $PSCommandPath -Kind 'Portable finalizer script') -cne $expectedFinalizer) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_INVOCATION_INVALID' 'The portable finalizer must run from the external staged transaction payload.' $PSCommandPath
}
$bootstrapPath = Assert-CcodPortableFinalizerRegularFile -Path (Join-Path $payloadRoot 'src\persistence\UninstallBootstrap.ps1') -Kind 'Staged uninstall bootstrap'
$portableModulePath = Assert-CcodPortableFinalizerRegularFile -Path (Join-Path $payloadRoot 'src\persistence\modules\PortableRelease.psm1') -Kind 'Staged portable release module'

# Give the launcher a brief handoff window. This is not an authorization check:
# transaction, identity, ACL, manifest, and marker checks below remain mandatory.
Start-Sleep -Milliseconds 750

. $bootstrapPath
$identity = Get-CcodUninstallBootstrapCurrentIdentity
$transaction = Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $transactionRoot -ExpectedUserSid $identity.userSid -IncludeCompleted
if ($null -eq $transaction -or $transaction.transactionId -cne $TransactionId -or $transaction.phase -cne 'ReadyForInno' -or $transaction.resumePhase -cne 'ReadyForInno') {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_TRANSACTION_INVALID' 'The portable uninstall transaction is not ready for finalization.' $transaction
}

Import-Module $portableModulePath -Force -ErrorAction Stop
$marker = Assert-CcodPortableInstalledMarker -InstallerRoot $expectedInstallerRoot
try {
    $markerGeneration = [uint64]$marker.generation
} catch {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_MARKER_INVALID' 'The portable installation marker generation is invalid.' $marker
}
if ($marker.runtimeId -cne $transaction.runtimeId -or $markerGeneration -ne [uint64]$transaction.runtimeGeneration) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_MARKER_INVALID' 'The portable installation marker does not bind the prepared runtime transaction.' $marker
}
if ([IO.Directory]::Exists($expectedInstallRoot) -or [IO.File]::Exists($expectedInstallRoot)) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_INSTALL_ROOT_PRESENT' 'Protected application state remains present after the cleanup boundary.' $expectedInstallRoot
}

Remove-CcodPortableInstallerRoot -InstallerRoot $expectedInstallerRoot | Out-Null
if ([IO.Directory]::Exists($expectedInstallerRoot) -or [IO.File]::Exists($expectedInstallerRoot)) {
    Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_REMOVE_FAILED' 'The verified portable installer root remains after removal.' $expectedInstallerRoot
}

# The staged bootstrap is intentionally invoked as a script: its entrypoint
# validates that its own PSCommandPath is the staged payload, writes the
# completion receipt, and terminates this detached finalizer process.
& $bootstrapPath -InstallerRoot $expectedInstallerRoot -InstallRoot $expectedInstallRoot -Mode FinalizeReceipt
Throw-CcodPortableFinalizerError 'CCOD_PORTABLE_FINALIZER_RECEIPT_INVALID' 'The staged finalization bootstrap returned without a completion receipt.' $TransactionId
