# v2.5.22 Transactional Install and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the unreleased v2.5.22 as a sealed, recoverable current-user
installation transaction whose final Setup and portable artifacts cannot become
public until they pass exact asset, Defender, and current-machine acceptance
gates.

**Architecture:** A private pinned file-transaction module replaces pathname
mutation for all lifecycle staging, promotion, and owned cleanup. A sealed
Setup package and locked temporary bootstrap feed that transaction, which
persists a monotonic phase record and compensates an unsuccessful post-pointer
upgrade. Release evidence is separate from product state: exact asset
contracts, dual Defender receipts, a clean runner, a private draft, and a
multi-reboot local acceptance record form a promotion chain.

**Tech Stack:** Windows PowerShell 5.1, .NET Framework/C# `Add-Type` interop,
Inno Setup 6, Node.js 22, GitHub Actions, Microsoft Defender, existing
PowerShell persistence self-tests.

**Spec:** `docs/superpowers/specs/2026-08-28-v2522-transactional-install-release-design.md`

## Global Constraints

- Keep the release version exactly `2.5.22`; it is not tagged or public.
- Never modify `ChatGPT.exe`, `app.asar`, `WindowsApps`, account state, or the
  DPAPI device-key store.
- Preserve the authenticated TrayHost wire schema and strict Codex process
  identity rules. Do not add a listener, a production test mode, or an external
  remote-control path.
- File mutations are authorized only by pinned parent identities plus
  single-segment leaves. Path checks, hashes, ADS checks, and link counts are
  validation layers, not authority for a later pathname write or delete.
- Every implementation change starts with a deterministic behavioral RED,
  followed by the smallest GREEN change, focused test evidence, a commit, and
  a scoped review.
- A failed pre-pointer transaction preserves the previous pointer and stable
  shell. A failed post-pointer transaction records a higher compensating
  generation or returns `CCOD_INSTALL_ROLLBACK_FAILED` without `Ready`.
- Use only clean, fresh build candidates. Existing `build/dist` assets are
  historical evidence and must never be uploaded, installed, or used for
  acceptance.
- Real Defender scans, GitHub draft/release operations, installation, Codex
  restart, Windows reboot, and second-device remote confirmation are final
  acceptance operations only; no task below performs them unless its command
  explicitly targets a disposable test fixture.
- All production and release receipts are bounded and sanitized: stable codes,
  hashes, version, commit, timestamps, and phases only; never credentials,
  DPAPI material, user paths, tokens, raw logs, or exception text.

---

### Task 1: Create private handle-bound installation file transactions

**Files:**
- Create: `src/persistence/modules/InstallFileTransaction.psm1`
- Create: `tests/persistence/InstallFileTransaction.SelfTest.ps1`
- Modify: `tests/PersistenceSelfTest.ps1`
- Modify: `tests/Validate.ps1`

**Interfaces:**

`InstallFileTransaction.psm1` owns all native handles and exposes only these
private module functions:

```powershell
Open-CcodInstallFileTransaction -InstallRoot <absolute-root>
Open-CcodInstallPinnedDirectory -Transaction <context> -ParentDirectory <pin> -Leaf <single-segment> [-CreateIfMissing]
New-CcodInstallPinnedTemporaryLeaf -Transaction <context> -ParentDirectory <pin> -Leaf <generated-single-segment>
Copy-CcodInstallSealedFile -Transaction <context> -SourcePath <absolute-file> -DestinationLeaf <pin> -ExpectedLength <int64> -ExpectedSha256 <lowercase-hex>
Commit-CcodInstallPinnedPromotion -Transaction <context> -ParentDirectory <pin> -TemporaryLeaf <pin> -DestinationLeaf <single-segment>
Write-CcodInstallPinnedJson -Transaction <context> -ParentDirectory <pin> -Leaf <single-segment> -Value <object> [-Compress]
Append-CcodInstallPinnedLog -Transaction <context> -ParentDirectory <pin> -Leaf <single-segment> -Record <sanitized-object>
Remove-CcodInstallOwnedTree -Transaction <context> -ParentDirectory <pin> -Leaf <single-segment>
Close-CcodInstallFileTransaction -Transaction <context> -Disposition Ready|Failed
```

The context includes the pinned install root, owned-object names, and all leaf
or directory handles. A caller may not pass an arbitrary destination pathname
to any mutation operation.

- [ ] **Step 1: Write deterministic failing transaction tests**

Create fixture helpers which make a temporary root and an outside sentinel.
Add one test for every native boundary:

```powershell
$tx = Open-CcodInstallFileTransaction -InstallRoot $install
$rootPin = $tx.RootDirectory
$child = Open-CcodInstallPinnedDirectory -Transaction $tx -ParentDirectory $rootPin -Leaf 'runtime' -CreateIfMissing
$result = Invoke-CcodAttemptDirectoryReplacement -Path (Join-Path $install 'runtime') -OutsideRoot $outside
Assert-CcodEqual 'blocked' $result.Outcome 'pinned missing directory cannot be replaced after creation'
```

Add RED cases for a replacement between temporary-leaf creation and promotion,
source-byte replacement after `Copy-CcodInstallSealedFile` opens the source,
reparse/ADS/multi-link leaves, a promotion whose parent was renamed, and a
owned-tree retirement containing an unknown, reparse, or multi-link leaf. Each
case must assert the outside sentinel remains unchanged and that failed cleanup
retains the unproven owned candidate. A normal nonempty owned tree must leave
its live name only through a no-replace atomic quarantine rename with every
original file preserved; an empty owned tree may be deleted on close.

Add REDs that a pinned JSON write and a pinned log append reject a replaced
state/log parent and cannot alter an outside sentinel. These operations become
the sole mutation route for the lifecycle's active pointer, runtime manifest,
phase record, activation receipt, UI state, and install log in Tasks 2–3.

- [ ] **Step 2: Run the new suite and confirm RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
```

Expected: the module/functions are absent and at least the missing-directory
pin case fails before any production mutation code exists.

- [ ] **Step 3: Implement the smallest private transaction module**

Use native `SafeFileHandle` operations with `FILE_OPEN_REPARSE_POINT` and
relative child opens/creates. Directory handles deny delete sharing for their
lifetime. Temporary leaves use create-new semantics; source and destination
bytes are read/written/hashed through the opened handles, flush completes
before promotion, and promotion is limited to the pinned parent. Retire a
complete nonempty transaction-owned candidate only by no-replace atomic rename
to a random quarantine leaf under the pinned parent. Mark only an empty owned
tree for delete-on-close. Any unexpected identity stops retirement and leaves
the candidate in place.

Do not import `LifecycleTransaction.psm1` or change any public wire schema;
this module is file-object ownership only.

- [ ] **Step 4: Run focused GREEN and aggregate registration checks**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck
```

Record any expected local mutex contamination separately; do not reinterpret it
as a pass. The new isolated transaction suite itself must exit zero.

- [ ] **Step 5: Commit**

```text
feat: add pinned install file transaction
```

### Task 2: Move lifecycle runtime data and stable-shell mutations onto the transaction

**Files:**
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `src/persistence/modules/StateStore.psm1`
- Modify: `src/persistence/modules/UiPreferences.psm1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/UninstallBootstrap.SelfTest.ps1`

**Interfaces:**

Task 2 imports `InstallFileTransaction.psm1` and changes internal lifecycle
composition to:

```powershell
Copy-CcodLifecycleStaging -SourceRoot <root> -InstallRoot <root> -FileTransaction <context> -Adapters <hashtable> -Files <object[]>
Commit-CcodLifecycleRuntime -FileTransaction <context> -StagingDirectory <pin> -RuntimeId <canonical-runtime-id>
Stage-CcodLifecycleStableShell -FileTransaction <context> -StagedRuntime <pin>
Commit-CcodLifecycleStableShell -FileTransaction <context> -StableShellCandidates <object>
Remove-CcodLifecycleOwnedRuntime -FileTransaction <context> -RuntimeId <canonical-runtime-id>
```

`Stage-CcodLifecycleStableShell` may only create verified candidates. It must
not overwrite stable `bootstrap.ps1` or
`Uninstall-CodexControlOtherDevices.ps1` before Task 3 has committed the active
pointer. `Commit-CcodLifecycleStableShell` runs only after pointer commit and
is therefore part of the monotonic compensation boundary.

- [ ] **Step 1: Write lifecycle RED cases before editing production paths**

Add deterministic adapters/barriers to the lifecycle suite. Assert all of:

```powershell
Assert-CcodThrows {
    Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $raceAdapters
} 'CCOD_INSTALL_FILE_TRANSACTION_INVALID'
Assert-CcodEqual $oldBootstrapHash (Get-CcodLifecycleFileSha256 $bootstrap) 'failed staging never changes stable bootstrap bytes'
Assert-CcodEqual $oldPointerJson (Get-Content $active -Raw) 'failed promotion never changes active pointer'
```

Cover a missing fresh `.staging`/`runtime` directory, a replacement after a
parent pin, a promotion failure, a stable-shell candidate hash failure, owned
old-runtime retirement after an unexpected leaf appears, and a legacy unknown
file that must be retained. Add REDs that runtime `manifest.json`, initial
state, and UI-preference writes use a pinned state/runtime parent. Keep the
current hard-link, ADS, reparse, and source-manifest coverage; adapt it to
prove mutation now goes through the new transaction module.

- [ ] **Step 2: Run the lifecycle suite and confirm RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Expected: at least one new barrier case proves that the current pathname
staging/promotion or early stable-shell copy is not transaction-bound.

- [ ] **Step 3: Replace runtime data and pre-pointer mutations**

Replace `Directory.CreateDirectory`, direct copy/move/replace, and
`Remove-Item -Recurse` mutation paths inside lifecycle staging, runtime
promotion, runtime manifest, initial state/UI preference, stable-shell
candidate handling, old-runtime retirement, and failed-candidate retirement with
Task 1 operations. Retain the existing process identity and scheduled-task
rules. Build/validate runtime manifest bytes through its pinned leaf before
promotion. Do not commit stable shell bytes yet; Task 3 commits them only after
the active-pointer transaction succeeds.

Do not change the external parameters of `Invoke-CcodInstall` in this task;
Task 3 adds the sealed package identity, active-pointer/receipt writes, and
transaction record.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

The source-level and disposable-fixture suites must exit zero. Do not stop the
real Supervisor merely to force the aggregate suite past its local mutex.

- [ ] **Step 5: Commit**

```text
fix: transact lifecycle file mutations
```

### Task 3: Persist installation phases and compensate post-pointer failures

**Files:**
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `src/persistence/modules/RuntimeManifest.psm1`
- Modify: `src/persistence/modules/PersistenceIO.psm1`
- Modify: `src/persistence/modules/StateStore.psm1`
- Modify: `src/persistence/modules/UiPreferences.psm1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/InstalledLifecycleHarness.SelfTest.ps1`

**Interfaces:**

Add private record helpers in `InstallLifecycle.psm1` and add the required
sealed package identity to the lifecycle call:

```powershell
New-CcodInstallTransactionRecord -TransactionId <lowercase-guid> -OldRuntimeId <nullable> -OldGeneration <nullable-uint64> -NewRuntimeId <nullable> -NewGeneration <uint64> -SealedPackageSha256 <lowercase-hex> -OwnedObjectNames <string[]>
Read-CcodInstallTransactionRecord -InstallRoot <absolute-root>
Set-CcodInstallTransactionPhase -InstallRoot <root> -TransactionId <guid> -ExpectedPhase <phase> -NewPhase <phase> -FileTransaction <context>
Invoke-CcodInstallCompensation -InstallRoot <root> -TransactionRecord <record> -FileTransaction <context> -Adapters <hashtable>

Invoke-CcodInstall ... -SealedPackageSha256 <lowercase-hex>
Set-CcodActiveRuntime ... -FileTransaction <context>
Write-CcodActivationReceiptFile ... -FileTransaction <context>
Write-CcodLifecycleLog ... -FileTransaction <context>
```

The only accepted persisted phases are `Prepared`, `PackageVerified`,
`RuntimeStaged`, `PreviousProtectionStopped`, `RuntimePromoted`,
`PointerCommitted`, `StableShellCommitted`, `ProtectionReady`, `Ready`, and
terminal `Failed`. `Failed` has the canonical transaction fields plus exactly
one stable `CCOD_*` error code; the reader rejects any other terminal phase or
additional field.

- [ ] **Step 1: Write phase and compensation RED cases**

For every phase through `RuntimePromoted`, inject a failure and assert the old
pointer, generation, and stable-shell hashes remain exactly unchanged. For each
phase starting at `PointerCommitted`, inject a failure and assert a higher
generation returns to the old runtime and old stable shell:

```powershell
Assert-CcodEqual 3 ([uint64]$finalPointer.generation) 'post-pointer compensation never decrements generation'
Assert-CcodEqual $oldRuntime $finalPointer.activeRuntime 'compensation reactivates retained old runtime'
Assert-CcodEqual 'CCOD_INSTALL_ROLLBACK_FAILED' $receipt.errorCode 'unproven compensation remains terminal failed'
```

Add REDs for a legacy installation with no record, same version/same sealed
hash idempotence, same version/different sealed hash
`CCOD_INSTALL_PACKAGE_CONFLICT`, malformed/expanded transaction JSON, and a
crash at each nonterminal phase. Assert `Ready` is impossible until active
pointer, manifest version, Supervisor, and authenticated TrayHost all match.
Add a RED that a canonical `Failed` record round-trips and that a missing,
noncanonical, duplicate, or private-data error field is rejected.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Expected: the phase-record helpers and monotonic compensation behavior are
absent or the new post-pointer expectations fail.

- [ ] **Step 3: Implement the record and recovery state machine**

Persist a bounded canonical JSON record with expected property order and no
absolute paths. Write the transaction record, active pointer, activation
progress/final receipt, lifecycle log, state updates, and UI preference only
through Task 1's pinned JSON/log operations. Move the record forward only after
the corresponding Task 2 file transaction commit. Commit active pointer before
stable shell. On a pre-pointer failure, retain the prior pointer and restart
the proved previous runtime when necessary. On a post-pointer failure, write
only a higher compensating generation, restore the matching stable shell
through the transaction module, and prove the previous Supervisor/TrayHost
before reporting failure. If any compensation proof fails, write `Failed` with
`CCOD_INSTALL_ROLLBACK_FAILED`, retain candidates, and do not cleanup by
pathname.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
```

All focused suites must exit zero. Record the known active-machine mutex only
if it occurs in an unrelated aggregate run.

- [ ] **Step 5: Commit**

```text
feat: recover installation transactions monotonically
```

### Task 4: Build a sealed Setup package and invoke a locked temporary bootstrap

**Files:**
- Create: `build/InstallerPackage.psm1`
- Modify: `build/build.ps1`
- Modify: `build/CodexControlOtherDevices.iss`
- Modify: `build/SetupArtifact.psm1`
- Modify: `tools/New-InstallerDestinationInventory.ps1`
- Modify: `Activate-CcodRemoteFix.ps1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`

**Interfaces:**

Add package creation/verification:

```powershell
New-CcodInstallerPackage -PayloadRoot <root> -PayloadManifestPath <manifest> -Version 2.5.22 -GitCommit <40hex> -OutputPath <absolute-zip> -ManifestOutputPath <absolute-json>
Test-CcodInstallerPackage -PackagePath <zip> -ManifestPath <json> -ExpectedPackageSha256 <hex> -ExpectedManifestSha256 <hex> -ExpectedVersion 2.5.22 -ExpectedGitCommit <40hex>
```

The compiled Setup receives `InstallerPackageSha256`,
`InstallerPackageManifestSha256`, `ActivationBootstrapSha256`,
`SetupGitCommit`, and `ProjectVersion`. Its activation path calls the locked
temporary bootstrap with:

```powershell
-PackagePath <private-temp-zip> -PackageManifestPath <private-temp-json>
-ExpectedPackageSha256 <hex> -ExpectedPackageManifestSha256 <hex>
-ExpectedVersion 2.5.22 -ExpectedGitCommit <40hex>
-InstallRoot <absolute-root> -ActivationId <lowercase-guid>
```

`Activate-CcodRemoteFix.ps1` verifies these inputs through opened handles and
passes the package hash as `-SealedPackageSha256` to Task 3's lifecycle.

- [ ] **Step 1: Write package and setup-boundary RED tests**

Extend the release workflow suite with a disposable package fixture. It must
reject omitted, extra, duplicate, unsafe-path, version-mismatched,
commit-mismatched, or hash-mismatched package contents before the install root
is created. Add a real compiled Inno fixture which asserts every pre-Ready
product output is absent, not merely recursive payload output:

```powershell
Assert-CcodFalse ($generatedSource -match 'DestDir:\s*"\{app\}\\payload') 'Setup does not recursively extract product payload into app'
Assert-CcodFalse ($generatedSource -match '-File "\{app\}\\Activate-CcodRemoteFix\.ps1"') 'Setup never executes activation from writable app'
Assert-CcodTrue ($generatedSource -match '(?m)^CreateAppDir=no$') 'Setup does not create an app directory before the transaction is Ready'
Assert-CcodTrue ($generatedSource -match '(?m)^Uninstallable=no$') 'Setup does not create a separate Inno uninstaller before the transaction is Ready'
Assert-CcodFalse (Test-CcodInnoPreReadyProductWrite -Source $generatedSource) 'Setup has no Files Icons Registry or UninstallRun product write before Ready'
```

Use a launch barrier after temporary bootstrap locking but before PowerShell
opens it. A replacement attempt must not alter the executed bytes. Add REDs
for a replaced package after validation, a stale legacy app script, missing
fresh `app/state/runtime` directories, a non-Ready receipt, and same-version
different-package conflict.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

Expected: the package module and compile-time bindings are absent, and the
current Inno source still exposes recursive payload copy or app-path execution.

- [ ] **Step 3: Implement sealed package build and bootstrap execution**

Build a single verified package and canonical package manifest from the
existing manifest-listed payload. Embed package, package manifest, and
bootstrap as `dontcopy` Setup inputs. Inno extracts them only to its private
temporary area, locks and rehashes them against compile-time constants, and
keeps the bootstrap lock through both activation and receipt validation.
Set `CreateAppDir=no` and `Uninstallable=no`; remove every `[Files]`, `[Icons]`,
`[Registry]`, and `[UninstallRun]` product write targeting `{app}` before
`Ready`, including docs/tools/diagnostic copies. Remove recursive `{app}`
payload extraction and all success-path execution of
`{app}\Activate-CcodRemoteFix.ps1`.

The bootstrap must use Tasks 1–3 to create/pin target directories and perform
the entire package-to-runtime transaction. Preserve the existing Inno `AppId`
and current-user scope as migration inputs, but do not alter a legacy uninstall
entry in this task; Task 5 registers its replacement only after `Ready`.
Extend Setup provenance/PE validation to bind all three new hashes plus version
and commit.

- [ ] **Step 4: Run focused GREEN and a clean disposable build**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
```

Then create a fresh detached candidate worktree at the exact current commit
whose `build/dist` does not yet exist, run the normal builder once there, and
verify its two release manifests against that worktree's exact `HEAD`. Do not
use or overwrite any existing `build/dist` directory.

- [ ] **Step 5: Commit**

```text
fix: seal setup package activation
```

### Task 5: Commit verified current-user product registration and shortcuts after Ready

**Files:**
- Create: `src/persistence/modules/ProductRegistration.psm1`
- Modify: `src/persistence/modules/InstallFileTransaction.psm1`
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `src/persistence/UninstallBootstrap.ps1`
- Modify: `Uninstall-CodexControlOtherDevices.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/UninstallBootstrap.SelfTest.ps1`
- Create: `tests/persistence/ProductRegistration.SelfTest.ps1`

**Interfaces:**

The registration module owns only the exact current-user product key and the
two exact current-user shortcut names and exposes:

```powershell
New-CcodProductRegistration -InstallRoot <absolute-root> -RuntimeId <canonical-runtime-id> -Version 2.5.22 -PackageSha256 <lowercase-hex>
Test-CcodProductRegistration -Registration <object> -ExpectedRuntimeId <canonical-runtime-id> -ExpectedVersion 2.5.22 -ExpectedPackageSha256 <lowercase-hex>
Commit-CcodProductRegistration -Registration <object> -FileTransaction <context> -Adapters <hashtable>
Remove-CcodLegacyProductRegistration -ExpectedAppId <canonical-guid> -Adapters <hashtable>
```

`InstallFileTransaction.psm1` additionally exposes internal fixed-root helpers
for the exact current-user Desktop and Start-menu Programs folders. They open
and pin only the resolved current-user special-folder identity, create only the
two approved `CodexRemote-fix.lnk` leaves, and copy verified shortcut-candidate
bytes through pinned handles; no product shortcut writer accepts an arbitrary
desktop/start-menu path.

The registration is written only after Task 3's `Ready` proof. It points to the
sealed stable uninstaller and creates exactly the Start-menu `CodexRemote-fix`
and desktop `CodexRemote-fix` shortcuts, both targeting the verified stable
bootstrap. All three records are read back and validated before the exact
legacy Inno uninstall registry entry and exact legacy shortcut names are
removed. It never recursively removes the legacy app tree or unrelated registry
values.

- [ ] **Step 1: Write legacy-registration RED tests**

Use registry and shortcut adapters in disposable fixtures. Add failures for
attempting a registration before `Ready`, an uninstaller or shortcut target
outside the sealed stable runtime, package/version/runtime mismatch, unreadable
registration, a legacy-key/name mismatch, a shortcut write failure, and a
registration write failure. Assert this boundary:

```powershell
Assert-CcodEqual $legacyUninstallString $world.LegacyUninstallString 'failure before read-back retains the legacy entry'
Assert-CcodFalse $world.LegacyEntryRemoved 'failed registration never removes legacy control-panel state'
Assert-CcodEqual 0 $world.LegacyShortcutRemovals 'failed registration never removes legacy shortcuts'
```

Add a RED that replaces the Desktop or Start-menu parent after it is opened;
shortcut promotion must block or fail with both outside sentinels unchanged.

Add a GREEN-target test that a valid `Ready` registration is read back first,
then only the exact legacy `AppId` entry and exact legacy shortcut names are
removed. Verify direct uninstaller and Windows Settings wrappers resolve the
current sealed registration, and Start-menu/desktop launchers resolve the
current sealed bootstrap.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
```

Expected: there is no private product-registration module and legacy
uninstaller/shortcut handling is still coupled to the Inno shell.

- [ ] **Step 3: Implement post-Ready registration migration**

Create the private module with strict current-user registry and shortcut
adapters, exact key/property/name allowlists, and read-back verification. Call
it after Task 3's final Ready revalidation and before old-runtime cleanup.
Generate shortcut candidates inside the sealed stable runtime, then promote
their bytes only through Task 1 pinned special-folder handles. The uninstaller
must revalidate its sealed runtime and transaction ownership before touching
product state. Failed registration or legacy removal leaves both entries and
both legacy shortcuts, reports a sanitized stable code, and does not turn an
already proved runtime into an unowned installation.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
feat: register product entry after readiness
```

### Task 6: Bind Defender evidence and an exact release asset contract

**Files:**
- Create: `tools/ReleaseAssetContract.psm1`
- Modify: `tools/Test-ReleaseDefender.ps1`
- Modify: `Install-CodexRemote-fix.ps1`
- Modify: `Activate-CcodRemoteFix.ps1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `build/build.ps1`
- Modify: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CHANGELOG.md`

**Interfaces:**

Define the exact 11 names in one module:

```powershell
Get-CcodExpectedReleaseAssetNames -Version 2.5.22
Test-CcodExactReleaseAssetSet -AssetDirectory <absolute-dir> -Version 2.5.22
Invoke-CcodReleaseDefenderCheck -CandidatePath <setup-or-zip> -ChecksumPath <checksum> -ManifestPath <matching-manifest> -Origin TrustedWorkflowArtifact|InternetDownload -ExpectedVersion 2.5.22 -ExpectedGitCommit <40hex> -EvidencePath <new-file>
Test-CcodReleasePromotionEvidence -EvidenceDirectory <absolute-dir> -Version 2.5.22 -ExpectedGitCommit <40hex>
```

For v2.5.22 the function returns exactly this ordered set, with no scan receipt
added to the public asset surface:

```text
CodexRemote-fix-2.5.22-windows-x64.zip
CodexRemote-fix-2.5.22-windows-x64.zip.sha256.txt
CodexRemote-fix-2.5.22-trayhost-provenance.json
CodexRemote-fix-2.5.22-payload-manifest.json
CodexRemote-fix-2.5.22-release-manifest.json
CodexRemote-fix-2.5.22-setup.exe
CodexRemote-fix-2.5.22-setup.exe.sha256.txt
CodexRemote-fix-2.5.22-setup-provenance.json
CodexRemote-fix-2.5.22-setup-payload-manifest.json
CodexRemote-fix-2.5.22-setup-destination-inventory.iss
CodexRemote-fix-2.5.22-setup-release-manifest.json
```

Each receipt binds asset type/SHA-256, manifest SHA-256, version, commit,
origin, Defender platform/signature information, signature timestamp,
scan timestamps, and zero new detections. It never records a source path or
raw Defender result.

- [ ] **Step 1: Write Defender and asset-contract RED tests**

Add deterministic adapters for the Defender tool and test that
`TrustedWorkflowArtifact` requires matching manifest/version/commit/hash
bindings, while `InternetDownload` requires an actual ZoneId 3 and has no
switch that synthesizes it. Add failure cases for disabled AV/real-time
protection, absent/stale signature data, scan error, new detection, existing
receipt, reparse evidence directory, and failed receipt write.

Add a two-asset matrix: Setup and portable ZIP must have distinct matching
receipts; a duplicate, swapped, missing, or mismatched receipt fails. Add
asset-set REDs for missing, extra, duplicate, case-varied, or reparse entries.
Finally, prove a portable scan failure prevents activation and a sealed Setup
package scan failure occurs before transaction-root/product state mutation.
Add a documentation RED that rejects the unqualified Chinese historical
“已验证……均可用” wording and any README or CHANGELOG claim that v2.5.22 is
stable before Task 9 records completed official-draft evidence.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

Expected: the exact asset module and origin-bound dual Defender receipt
contract are not present.

- [ ] **Step 3: Implement the bounded evidence contract**

Move exact asset-name construction into `ReleaseAssetContract.psm1`. Make
release manifest/build validation consume that one contract. Extend the
Defender tool with explicit origins and strict platform, service, real-time,
signature, manifest, and receipt validation. Keep the portable scan behavior;
add the sealed Setup package scan to Task 4's bootstrap before `Prepared`.
Correct both README files and CHANGELOG so they describe only the scan paths
actually enforced, list the exact public asset set, and describe v2.5.22 as a
candidate until Task 9's externally recorded acceptance is complete.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\PortableRelease.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

These tests prove deterministic contracts only. A real Defender scan remains a
final external acceptance action and must not be mocked as a live pass.

- [ ] **Step 5: Commit**

```text
feat: gate releases on dual Defender evidence
```

### Task 7: Stage exact draft assets behind clean-runner and promotion gates

**Files:**
- Create: `tools/Test-CleanReleaseRunner.ps1`
- Create: `tools/Invoke-GitHubDraftRelease.ps1`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Modify: `tests/persistence/Bootstrap.SelfTest.ps1`

**Interfaces:**

```powershell
Test-CcodCleanReleaseRunner -RepositoryRoot <absolute-root> -ExpectedVersion 2.5.22
Invoke-CcodGitHubDraftRelease -Mode Stage|Verify|Promote -Tag v2.5.22 -AssetDirectory <absolute-dir> -EvidenceDirectory <absolute-dir>
```

`Test-CcodCleanReleaseRunner` returns stable failure
`CCOD_CLEAN_RUNNER_CONTAMINATED` if a CodexRemote-fix runtime root, task,
Supervisor/TrayHost, or AccountTransition/AccountSupervisor mutex is present.
It performs no cleanup. `Invoke-CcodGitHubDraftRelease` uses injected adapters
in tests, consumes the Task 6 exact asset contract, and never discovers assets
by extension glob.

- [ ] **Step 1: Write workflow and runner RED tests**

Add fixtures proving that an occupied mutex, existing product state, a missing
clean preflight, `continue-on-error`, a conditional bypass, a rebuilt publish
candidate, or an unpinned action reference rejects the workflow before any
test/build/publish step. Add script tests that Stage cannot create a public
release, upload failure leaves a draft private, and Verify downloads/rechecks
all 11 assets before any Promote path.

Add promotion REDs for missing dual Defender evidence, mismatched receipt,
missing accepted reboot phase, missing legacy-upgrade evidence, or missing
reviewed manual evidence. Require
same-tag workflow concurrency and an explicit mode transition; tag pushes may
stage only, never publicize.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
```

Expected: the current workflow either lacks clean preflight, uses a public
release first, accepts extension-based asset discovery, or has no explicit
promotion evidence gate.

- [ ] **Step 3: Implement the clean/draft workflow contract**

Add a clean preflight before source validation, TrayHost traces, and build.
The build job creates exactly one candidate; later jobs only download, hash,
and validate it. Stage creates a GitHub draft with the exact 11-item allowlist,
verifies read-back, and preserves the draft on failure. A tag-triggered workflow
can Stage only; it cannot call Promote. `InternetDownload` scan receipts are
produced by Task 8 after the user downloads the official draft in a browser and
retains ZoneId 3. `Promote` runs only through the local, adapter-tested command
after Task 8 and Task 9 evidence has been verified; it changes the already
verified draft to public without rebuilding assets. Pin the current reviewed
action sources exactly as follows and add same-tag concurrency:

```text
actions/checkout@11d5960a326750d5838078e36cf38b85af677262
actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020
actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093
```

Do not run a real `gh` command from a test or a task implementation command.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck
```

Confirm each source-level suite exits zero; a local active product mutex is
recorded as environmental contamination, not a skipped clean-runner gate.

- [ ] **Step 5: Commit**

```text
fix: stage releases behind clean promotion gates
```

### Task 8: Record official-draft upgrade, reinstall, and reboot acceptance

**Files:**
- Create: `tests/installed/OfficialDraftAcceptance.psm1`
- Create: `tests/installed/Invoke-OfficialDraftAcceptance.ps1`
- Create: `tests/persistence/OfficialDraftAcceptanceHarness.SelfTest.ps1`
- Modify: `tests/installed/Invoke-InstalledLifecycleIntegration.ps1`
- Modify: `tests/persistence/InstalledLifecycleHarness.SelfTest.ps1`
- Modify: `tests/Validate.ps1`

**Interfaces:**

```powershell
Invoke-CcodOfficialDraftAcceptance `
  -Phase Preflight|LegacyUpgrade|Uninstall|FreshInstall|PreReboot|PostReboot|ReadyForManualEvidence `
  -AssetDirectory <official-draft-download> `
  -PreviousAssetDirectory <official-current-release-download> `
  -EvidenceRoot <absolute-nonreparse-root> `
  -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot
```

The persisted acceptance receipt contains only candidate/manifest hashes,
draft tag/ID, phase, and sanitized facts. It has no account content, device-key
content, private path, raw token, or raw log text. Task 9 appends manually
reviewed evidence hashes only after the automated phases are complete.

- [ ] **Step 1: Write phase-machine RED tests**

Add tests that fail before any adapter mutation if the official draft lacks one
of 11 exact assets, manifests/commit/hashes do not match, a caller lacks the
relevant allow switch, or a phase is out of order/reused with a different
candidate. `Preflight` is the only phase allowed to create dual Defender
receipts; every later phase must reject missing, swapped, or mismatched receipts.

`Preflight` must invoke `Invoke-CcodReleaseDefenderCheck` once for the official
browser-downloaded Setup and once for the portable ZIP with
`-Origin InternetDownload`, then persist both exact receipts before any machine
mutation. Add a legacy-upgrade RED requiring the manifest-bound currently
public v2.5.21 Setup asset and asserting the sealed migration preserves the
DPAPI key hash. Add REDs requiring: uninstall proves task, Supervisor, TrayHost,
runtime/app root, shortcuts, and expected debug endpoints are gone while the
DPAPI key hash is unchanged; fresh install/repair proves active pointer,
manifest, generation, one authenticated TrayHost, task, terminal receipt, and
post-reboot proves a new boot ID, `Idle` transition, auto-recovered protection,
and the same key hash.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
```

Expected: the phase API and tamper-resistant evidence contract are absent.

- [ ] **Step 3: Implement the fixture-safe acceptance orchestrator**

Implement all phases using injectable adapters so self-tests never touch the
real machine. Integrate existing lifecycle observations but strengthen their
assertions as listed above. `LegacyUpgrade` may run only after two valid
InternetDownload receipts; `Uninstall` follows a proved legacy upgrade;
`FreshInstall` follows a proved uninstall; and `PostReboot` rejects a missing
or altered pre-reboot receipt. `ReadyForManualEvidence` requires all automated
phases but cannot become `Complete`. Add it to validation only in self-test
mode. Do not trigger an actual uninstall, restart, reboot, tray click, or
remote session in automated tests.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck
```

The real phase sequence happens only after all implementation/review/build
gates pass, using official browser-downloaded draft and current-release assets
plus the explicit user-authorized machine mutation/reboot switches.

- [ ] **Step 5: Commit**

```text
test: require official draft acceptance evidence
```

### Task 9: Require individual tray and remote evidence before promotion

**Files:**
- Modify: `tests/installed/OfficialDraftAcceptance.psm1`
- Modify: `tests/installed/Invoke-OfficialDraftAcceptance.ps1`
- Modify: `tests/persistence/OfficialDraftAcceptanceHarness.SelfTest.ps1`
- Modify: `tools/Invoke-GitHubDraftRelease.ps1`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CHANGELOG.md`

**Interfaces:**

Extend only the completed Task 8 receipt chain:

```powershell
Invoke-CcodOfficialDraftAcceptance `
  -Phase TrayEvidence|RemoteEvidence|Complete `
  [-TrayOperation About|Language|OpenLogs|Repair] `
  [-RemoteOperation SecondDeviceControl] `
  -EvidenceRoot <absolute-nonreparse-root> `
  -ScreenshotPath <regular-file> `
  -RedactedLogPath <regular-file> `
  -ReviewState Reviewed
```

`TrayEvidence` stores one bounded record for each of `About`, `Language`,
`OpenLogs`, and `Repair`, including its expected terminal state and hashes of
the corresponding screenshot and redacted log. `RemoteEvidence` stores the
second-device connection/control result the same way. `Complete` requires the
five named evidence records plus every Task 8 phase; it does not accept a free
text confirmation.

- [ ] **Step 1: Write tray/remote evidence RED tests**

Add tests proving that `TrayEvidence` fails if any of the four named operations
is missing, duplicated, has an unexpected terminal state, shares another
operation's file hash, uses a reparse/non-file evidence path, or omits
`Reviewed`. Add tests that `RemoteEvidence` fails without a distinct
second-device proof. Assert `Complete` rejects a `ReadyForManualEvidence`
receipt lacking any individual operation:

```powershell
Assert-CcodThrows {
    Invoke-CcodOfficialDraftAcceptance -Phase Complete -EvidenceRoot $evidence -Adapters $fake
} 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INCOMPLETE'
```

Add docs REDs requiring the Chinese README to remove the old unconditional
“已验证……均可用” claim and both READMEs/CHANGELOG to remain candidate-oriented
until `Complete` is represented by evidence, rather than a guessed statement.

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
```

Expected: the acceptance phase API accepts no individual tray/remote evidence
or has no `Complete` evidence gate.

- [ ] **Step 3: Implement the bounded manual-evidence gate**

Validate the file hash and review state through injectable adapters, retain
only the allowed named operation/result/hash fields, and chain every record to
the exact Task 8 candidate receipt. Add `Invoke-CcodGitHubDraftRelease -Mode
Promote` validation of this completed evidence before it is permitted to make a
draft public. Correct both README files and CHANGELOG to avoid unsupported
stable claims; release notes may report only the recorded acceptance facts.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

Real screenshots, tray actions, remote connection, and final promotion remain
the user-authorized final acceptance operation; fixture tests must not open a
real tray, switch a language, trigger repair, reboot, or control another
device.

- [ ] **Step 5: Commit**

```text
test: gate promotion on tray and remote evidence
```

## Plan self-review

| Spec requirement | Implementing task |
| --- | --- |
| Pinned relative copies, promotion, and owned delete | Task 1 and Task 2 |
| Fresh install, legacy upgrade, same-version conflict, and recovery | Task 2, Task 3, Task 4, Task 5, and Task 8 |
| Sealed package and no writable-app activation execution | Task 4 and Task 5 |
| Monotonic post-pointer compensation and strict `Ready` | Task 3 |
| Dual Defender evidence and exact 11 assets | Task 6 and Task 8 |
| Clean candidate build and draft-only promotion | Task 7 and Task 9 |
| Official draft uninstall/reboot/tray/remote acceptance | Task 8 and Task 9 |

No task adds a control channel, relaxes process identity, modifies Codex
binaries, or lets existing historical build artifacts re-enter a release.
Tasks share files only in dependency order: Tasks 1–4 form the installation
transaction chain; Task 5 commits legacy uninstall migration only after Task 3
Ready; Task 6 consumes Task 4's sealed package; Task 7 consumes Task 6's
receipt/asset contract; Task 8 consumes Tasks 3–7 and produces official-draft
Defender/upgrade/reboot evidence; Task 9 adds individual tray/remote evidence
and is the only task that authorizes the locally executed Promote command to
consider a draft eligible for public release.
