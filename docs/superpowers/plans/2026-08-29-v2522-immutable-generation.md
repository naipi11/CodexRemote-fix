# v2.5.22 Immutable Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the unreleased v2.5.22 install and upgrade flow create only
complete immutable generations, atomically select one active generation, and
prove official draft assets on the current machine before public promotion.

**Architecture:** The file layer creates and verifies unique generation trees
with private handle capabilities and never overwrites an existing generation
or recursively deletes a nonempty tree during install. The lifecycle appends a
bounded phase record and uses a monotonic pointer/compensation protocol. Inno
Setup is a bootstrap-only shell, while dual Defender receipts, exact assets,
old-version upgrade, reboot, tray, and remote evidence form the final release
promotion chain.

**Tech Stack:** Windows PowerShell 5.1, .NET Framework/C# native interop,
Inno Setup 6, Node.js 22, GitHub Actions, Microsoft Defender, existing
PowerShell persistence and TrayHost self-tests.

**Spec:** `docs/superpowers/specs/2026-08-29-v2522-immutable-generation-design.md`

## Global Constraints

- Keep the unreleased version exactly `2.5.22`; no tag or public release is
  created until the final external acceptance task.
- Never modify `ChatGPT.exe`, `app.asar`, `WindowsApps`, account state, or the
  DPAPI device-key store.
- Preserve authenticated TrayHost wire messages, process identity checks, and
  current-user installation semantics. Do not add a control channel, listener,
  production test switch, or remote protocol.
- The product's security boundary is current-user integrity and ordinary race
  resistance. Do not claim protection against a same-user process with
  unrestricted write/DACL authority; an elevated/signed broker is out of scope.
- Staging creates unique generation files only. Existing generations and stable
  files are never overwritten before readiness. Install-time cleanup retires
  or retains old generations; it never recursively deletes a nonempty tree.
- A failed pre-pointer phase leaves the old pointer and stable shell unchanged.
  A post-pointer failure writes a higher compensating pointer or terminal
  `Failed/CCOD_INSTALL_ROLLBACK_FAILED`; it never decrements a generation.
- `Ready` requires matching pointer, generation manifest, expected version,
  Supervisor, authenticated TrayHost, and activation receipt.
- Setup/portable assets are selected by an explicit 11-name allowlist, not an
  extension glob. Public promotion requires two real downloaded-asset Defender
  receipts, complete automated acceptance, and individual manual evidence.
- Every production change follows TDD RED → GREEN → focused review. Test
  fixtures must not stop or start the real current-machine product.

---

### Task 1: Reduce the file layer to immutable generation primitives

**Files:**
- Modify: `src/persistence/modules/InstallFileTransaction.psm1`
- Modify: `tests/persistence/InstallFileTransaction.SelfTest.ps1`
- Modify: `tests/PersistenceSelfTest.ps1`
- Modify: `tests/Validate.ps1`

**Interfaces:**

Replace the failed DACL/retirement implementation with these private
create-only operations:

```powershell
Open-CcodInstallGeneration -InstallRoot <absolute-root> -RuntimeId <unique-id>
New-CcodInstallGenerationLeaf -Generation <opaque-generation> -Leaf <single-segment>
Copy-CcodInstallSealedSource -Generation <opaque-generation> -SourcePath <sealed-source> -Leaf <single-segment> -ExpectedLength <int64> -ExpectedSha256 <lowercase-hex>
Write-CcodInstallGenerationManifest -Generation <opaque-generation> -Manifest <object>
Commit-CcodInstallActivePointer -InstallRoot <absolute-root> -ExpectedPreviousGeneration <uint64> -NewRuntimeId <unique-id> -FileTransaction <opaque-context>
Retire-CcodInstallGeneration -InstallRoot <absolute-root> -RuntimeId <owned-id> -FileTransaction <opaque-context>
Close-CcodInstallFileTransaction -Transaction <opaque-context> -Disposition Ready|Failed
```

Capabilities are opaque reference tokens stored in module-private state. The
CLR bridge exposes only a non-mutating marker; no public method accepts an
arbitrary path or bare handle. There is no persistent DACL change and no
nonempty recursive deletion operation.

- [ ] **Step 1: Write failing immutable-generation tests**

Add RED cases proving a duplicate generation ID, destination leaf, or pointer
generation is rejected without changing the existing object. Add barriers for
source replacement after handle open, generation manifest mutation after
write, invalid reparse/ADS/multilink entries, forged/cross-transaction
capabilities, and native handle close during a relative operation. Add a
nonempty generation case whose live name is atomically retired to a unique
owned quarantine name and whose bytes remain readable and unchanged.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
```

Expected: the new immutable names/operations are absent or the current DACL
retirement/overwrite behavior fails the new assertions.

- [ ] **Step 3: Implement minimal immutable file primitives**

Use relative native creates under a validated generation parent, create-new
leaf semantics, private source/destination handles, flush plus same-handle
length/SHA-256 verification, and opaque capabilities. A destination that
already exists fails with a stable collision code. Retire only a fully proven
owned generation by no-replace relative rename; retain the quarantine tree.

- [ ] **Step 4: Run GREEN and registration checks**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck
```

The focused suite must exit zero. If the aggregate reaches the known local
Bootstrap fallback/mutex boundary, record the exact case as environmental and
not as a pass.

- [ ] **Step 5: Commit**

```text
fix: use immutable generation file primitives
```

### Task 2: Migrate lifecycle data and pointer commits to immutable generations

**Files:**
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `src/persistence/modules/RuntimeManifest.psm1`
- Modify: `src/persistence/modules/PersistenceIO.psm1`
- Modify: `src/persistence/modules/StateStore.psm1`
- Modify: `src/persistence/modules/UiPreferences.psm1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/RuntimeManifest.SelfTest.ps1`
- Modify: `tests/persistence/UninstallBootstrap.SelfTest.ps1`

**Interfaces:**

`Invoke-CcodInstall` consumes `-SealedPackageSha256` and a Task 1 opaque
transaction. These private operations are added or adapted:

```powershell
New-CcodInstallTransactionRecord -TransactionId <guid> -OldRuntimeId <nullable> -OldGeneration <nullable-uint64> -NewRuntimeId <nullable> -NewGeneration <uint64> -SealedPackageSha256 <hex> -OwnedObjectNames <string[]>
Read-CcodInstallTransactionRecord -InstallRoot <absolute-root>
Set-CcodInstallTransactionPhase -InstallRoot <root> -TransactionId <guid> -ExpectedPhase <phase> -NewPhase <phase> -FileTransaction <context>
Set-CcodActiveRuntime -InstallRoot <root> -NewRuntimeId <unique-id> -FileTransaction <context> -Ownership <fence>
Write-CcodActivationReceiptFile -InstallRoot <root> -Receipt <object> -FileTransaction <context>
Invoke-CcodInstallCompensation -InstallRoot <root> -TransactionRecord <record> -FileTransaction <context> -Adapters <hashtable>
```

The only phases are `Prepared`, `PackageVerified`, `RuntimeStaged`,
`PreviousProtectionStopped`, `RuntimePromoted`, `PointerCommitted`,
`StableShellCommitted`, `ProtectionReady`, `Ready`, and terminal `Failed`.

- [ ] **Step 1: Write lifecycle RED cases**

Inject failures through every phase. Assert pre-pointer failures leave the old
pointer, generation, stable bootstrap, and uninstaller bytes unchanged. Assert
post-pointer failures produce a higher compensating generation targeting the
old runtime, or `Failed/CCOD_INSTALL_ROLLBACK_FAILED` while retaining both
generations. Add tests for same-version/same-package idempotence,
same-version/different-package `CCOD_INSTALL_PACKAGE_CONFLICT`, legacy installs
without a transaction record, malformed phase records, and a pointer/manifests
drift immediately before `Ready`.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Expected: current path-based staging or pointer/receipt writes fail at the new
phase and compensation expectations.

- [ ] **Step 3: Implement the immutable lifecycle data plane**

Create a unique generation and write every runtime file, manifest, state file,
UI preference, transaction record, activation receipt, and sanitized lifecycle
log through Task 1 create-only operations. Commit the active pointer atomically
after runtime validation and before stable-shell commit. Never overwrite an
existing generation or use `Remove-Item -Recurse` in install/recovery paths.
On failure, retire or retain only owned candidates; do not delete unknown
legacy files.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
fix: commit lifecycle through immutable generations
```

### Task 3: Build the sealed Setup package and bootstrap it without `{app}` writes

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

```powershell
New-CcodInstallerPackage -PayloadRoot <root> -PayloadManifestPath <manifest> -Version 2.5.22 -GitCommit <40hex> -OutputPath <absolute-zip> -ManifestOutputPath <absolute-json>
Test-CcodInstallerPackage -PackagePath <zip> -ManifestPath <json> -ExpectedPackageSha256 <hex> -ExpectedManifestSha256 <hex> -ExpectedVersion 2.5.22 -ExpectedGitCommit <40hex>
```

The Setup compiler binds `InstallerPackageSha256`,
`InstallerPackageManifestSha256`, `ActivationBootstrapSha256`,
`SetupGitCommit`, and `ProjectVersion`. Package, manifest, and bootstrap are
`dontcopy` temporary inputs. Inno sets `CreateAppDir=no` and
`Uninstallable=no`; its source has no pre-Ready `{app}` `[Files]`, `[Icons]`,
`[Registry]`, or `[UninstallRun]` product write. The bootstrap scans the sealed
package, invokes Task 2, and Setup accepts only strict `Ready`.

- [ ] **Step 1: Write package/bootstrap RED tests**

Reject missing/extra/duplicate/unsafe package entries and every version,
commit, manifest, or package-hash mismatch before creating product state. Add a
real compiled Inno fixture that fails if any pre-Ready `{app}` product write,
recursive payload extraction, or `-File "{app}\Activate-CcodRemoteFix.ps1"`
success path remains. Add a temporary-bootstrap replacement barrier proving
the locked source bytes are the bytes executed.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

- [ ] **Step 3: Implement package binding and Setup bootstrap**

Create/test the package archive from the existing manifest-listed payload.
Extract and hash-bind only the temporary package, manifest, and bootstrap;
retain their read-only handles through activation and terminal validation. Do
not let Setup write product payloads into `{app}`. Ensure the bootstrap uses
Task 2 and does not discover or execute a stale legacy app script.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
fix: bootstrap sealed installer package
```

### Task 4: Register the product and shortcuts only after Ready

**Files:**
- Create: `src/persistence/modules/ProductRegistration.psm1`
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `src/persistence/modules/InstallFileTransaction.psm1`
- Modify: `src/persistence/UninstallBootstrap.ps1`
- Modify: `Uninstall-CodexControlOtherDevices.ps1`
- Create: `tests/persistence/ProductRegistration.SelfTest.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/UninstallBootstrap.SelfTest.ps1`

**Interfaces:**

```powershell
New-CcodProductRegistration -InstallRoot <absolute-root> -RuntimeId <unique-id> -Version 2.5.22 -PackageSha256 <hex> -FileTransaction <context>
Test-CcodProductRegistration -Registration <object> -ExpectedRuntimeId <unique-id> -ExpectedVersion 2.5.22 -ExpectedPackageSha256 <hex>
Commit-CcodProductRegistration -Registration <object> -FileTransaction <context> -Adapters <hashtable>
Remove-CcodLegacyProductRegistration -ExpectedAppId <canonical-guid> -Adapters <hashtable>
```

The module writes/read-backs exactly the current-user uninstall registration,
Start-menu `CodexRemote-fix.lnk`, and desktop `CodexRemote-fix.lnk`. Shortcut
candidate bytes are generated in a sealed runtime and copied through fixed
current-user special-folder handles; arbitrary shortcut paths are rejected.

- [ ] **Step 1: Write registration RED tests**

Prove registration/shortcut writes before `Ready`, path/target mismatches,
legacy-key mismatch, special-folder replacement, and write/read-back failures
leave legacy registration and shortcut names untouched. Prove a valid Ready
record reads back all three new records before removing only the exact legacy
entries.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
```

- [ ] **Step 3: Implement post-Ready registration**

Call the module only after Task 2's final `Ready` proof. Preserve legacy entries
on any failure. Make direct uninstaller and Windows Settings launch the sealed
stable generation and never remove unknown files/registry values.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
feat: register product only after readiness
```

### Task 5: Enforce dual Defender receipts and the exact 11-asset contract

**Files:**
- Create: `tools/ReleaseAssetContract.psm1`
- Modify: `tools/Test-ReleaseDefender.ps1`
- Modify: `Install-CodexRemote-fix.ps1`
- Modify: `Activate-CcodRemoteFix.ps1`
- Modify: `build/build.ps1`
- Modify: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CHANGELOG.md`

**Interfaces:**

```powershell
Get-CcodExpectedReleaseAssetNames -Version 2.5.22
Test-CcodExactReleaseAssetSet -AssetDirectory <absolute-dir> -Version 2.5.22
Invoke-CcodReleaseDefenderCheck -CandidatePath <setup-or-zip> -ChecksumPath <checksum> -ManifestPath <matching-manifest> -Origin TrustedWorkflowArtifact|InternetDownload -ExpectedVersion 2.5.22 -ExpectedGitCommit <40hex> -EvidencePath <new-file>
Test-CcodReleasePromotionEvidence -EvidenceDirectory <absolute-dir> -Version 2.5.22 -ExpectedGitCommit <40hex>
```

The explicit public assets are:

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

Receipts are evidence only, not public assets. A receipt binds asset type/hash,
matching manifest hash, version, commit, origin, Defender service/AV/real-time
state, signature/platform versions and timestamps, and zero new detections.

- [ ] **Step 1: Write Defender/asset RED tests**

Add failures for missing/extra/case-varied/reparse assets, every receipt binding
mismatch, duplicate/swapped/missing Setup/ZIP receipt, disabled Defender or
real-time protection, missing/stale signatures, scan errors, detections,
existing/reparse evidence files, and portable/Setup scan failure before any
activation state is created. Add documentation REDs rejecting the old Chinese
“已验证……均可用” wording and unqualified stable claims.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

- [ ] **Step 3: Implement the contract**

Centralize asset names and manifest checks. Keep `InternetDownload` strict
about actual ZoneId 3; allow `TrustedWorkflowArtifact` only with a matching
workflow artifact identity. Add the Setup scan before `Prepared`, preserve the
portable scan, and make README/CHANGELOG describe only enforced behavior.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\PortableRelease.SelfTest.ps1
```

These are deterministic contracts; live Defender evidence is produced only by
Task 7 on the official downloaded draft.

- [ ] **Step 5: Commit**

```text
feat: require dual Defender release evidence
```

### Task 6: Add clean-runner and draft-only release promotion

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

`Stage` runs only after clean preflight, validation, traces, and build. It
creates a private draft, uploads exactly the 11 names above, and reads every
asset back. `Promote` is local and cannot rebuild; it requires Task 5 receipts
and Task 8/9 acceptance evidence. Pin Actions to the reviewed commits:

```text
actions/checkout@11d5960a326750d5838078e36cf38b85af677262
actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020
actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093
```

- [ ] **Step 1: Write workflow RED tests**

Reject an installed state, occupied account mutex, dirty checkout, missing
preflight, unpinned action, extension glob, extra/missing asset, public-first
release, upload failure that calls public promotion, rebuilt publish candidate,
missing dual receipt, missing acceptance evidence, conditional bypass,
`continue-on-error`, or same-tag concurrent stage.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
```

- [ ] **Step 3: Implement clean/draft workflow**

Make clean preflight the first release job, transfer one immutable candidate
between jobs, and never rebuild in publish. Stage leaves a draft private on
any failure. Verify performs exact manifest/hash read-back. Promote requires
the evidence directory and changes only the already verified draft.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
fix: stage releases behind draft promotion gates
```

### Task 7: Build the official-draft acceptance state machine

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
  -PreviousAssetDirectory <official-v2.5.21-download> `
  -EvidenceRoot <absolute-nonreparse-root> `
  -AllowMachineMutation -AllowCodexRestart -AllowWindowsReboot
```

`Preflight` downloads must retain actual ZoneId 3 and invokes the real Defender
checker once for Setup and once for portable before any machine mutation. The
legacy upgrade must use a checksum/manifest-bound public v2.5.21 Setup. The
receipt is append-only and contains only candidate/manifest hashes, tag/ID,
phase, and sanitized facts.

- [ ] **Step 1: Write acceptance RED tests**

Before any adapter mutation, reject missing/extra assets, bad manifest/commit/
hash, missing dual scan receipts, missing authorization switches, wrong phase
order, candidate changes, and receipt tampering. Add fixtures requiring the
legacy upgrade, complete uninstall with unchanged DPAPI key hash, fresh
install, pre/post reboot identity, one Supervisor/TrayHost, Idle transition,
and strict active generation/Ready facts.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
```

- [ ] **Step 3: Implement fixture-safe phase orchestration**

Use injectable adapters for all tests. The real runner performs the exact
sequence `Preflight → LegacyUpgrade → Uninstall → FreshInstall → PreReboot →
PostReboot → ReadyForManualEvidence`; no automated fixture starts a real
installer or reboots Windows.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
test: record official draft lifecycle acceptance
```

### Task 8: Require manual tray/remote evidence and prepare promotion

**Files:**
- Modify: `tests/installed/OfficialDraftAcceptance.psm1`
- Modify: `tests/installed/Invoke-OfficialDraftAcceptance.ps1`
- Modify: `tests/persistence/OfficialDraftAcceptanceHarness.SelfTest.ps1`
- Modify: `tools/Invoke-GitHubDraftRelease.ps1`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CHANGELOG.md`

**Interfaces:**

```powershell
Invoke-CcodOfficialDraftAcceptance -Phase TrayEvidence|RemoteEvidence|Complete -TrayOperation About|Language|OpenLogs|Repair -RemoteOperation SecondDeviceControl -EvidenceRoot <absolute-root> -ScreenshotPath <regular-file> -RedactedLogPath <regular-file> -ReviewState Reviewed
```

`TrayEvidence` requires one reviewed record for each named operation, with
expected terminal state and distinct screenshot/log hashes. `RemoteEvidence`
requires the second device to discover, connect, and control this device.
`Complete` requires all five manual records plus every Task 7 phase; it is not a
free-text confirmation. `Promote` requires `Complete` and the two live Defender
receipts before making the draft public.

- [ ] **Step 1: Write manual-evidence RED tests**

Reject missing, duplicate, unreviewed, reused, non-file, reparse, or
cross-candidate evidence. Reject completion without all four tray operations,
second-device control, or the Task 7 receipt chain. Assert documentation has
no unqualified “stable/verified” claim before evidence.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
```

- [ ] **Step 3: Implement the promotion evidence gate and concise docs**

Hash and review only bounded screenshot/redacted-log files. Keep both READMEs
candidate-oriented and keep technical details in CHANGELOG/release notes. The
promotion command must fail closed unless the exact draft, dual real scan
receipts, full lifecycle receipt, and all five manual records match.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\OfficialDraftAcceptanceHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

- [ ] **Step 5: Commit**

```text
test: gate release on tray and remote evidence
```

## Final verification and external acceptance (after all task reviews)

1. Create a fresh detached worktree at the final reviewed commit; ensure no
   pre-existing `build/dist` and run the clean-runner preflight.
2. Run the full clean-runner suite, including `npm test`, installed lifecycle,
   release contract, TrayHost protocol/production/trace, the build, and both
   manifest validators. Any nonzero stops publication.
3. Run `Stage` to create the private official draft. Download Setup and ZIP in
   the browser so ZoneId 3 is real; run the two live Defender scans and save
   receipts before machine mutation.
4. Use the manifest-bound public v2.5.21 Setup for `LegacyUpgrade`, then
   complete `Uninstall`, `FreshInstall`, `PreReboot`, and `PostReboot` with the
   explicit user-authorized machine mutation/reboot switches.
5. Manually perform and record About, language switching, Open logs, Repair,
   and second-device connection/control. Only a reviewed `Complete` receipt
   permits local `Promote` of the already verified draft.
6. After promotion, re-download the public assets, re-run exact manifest/hash
   validation, and verify the public tag points to the final reviewed commit.
