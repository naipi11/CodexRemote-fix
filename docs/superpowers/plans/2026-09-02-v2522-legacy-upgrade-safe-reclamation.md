# Legacy Upgrade and Safe Reclamation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make real v2.5.21 and supported older installations converge to v2.5.22, migrate their exact product records, and reclaim an installed generation without pathname TOCTOU.

**Architecture:** First classify legacy `active.json` state as an explicit pre-append-only upgrade source instead of demanding a nonexistent Ready transaction. Then migrate legacy registration by matching one complete known installer profile rather than the impossible union of all historical shortcut names. Finally replace recursive pathname deletion with a bounded native handle-pinned reclamation operation that re-proves the sealed tree and deletes only held identities.

**Tech Stack:** Windows PowerShell 5.1, Inno Setup source history, V4 immutable file layer, Windows native file handles, existing lifecycle/product/uninstall self-tests.

**Spec:** `docs/superpowers/specs/2026-08-29-v2522-immutable-generation-design.md`

## Global Constraints

- Work only in the existing isolated worktree; preserve current dirty/user state outside it.
- No real registry, shortcut, scheduled task, installed product, installer, network, release, push, installation, reboot, or external action.
- True legacy acceptance is limited to exact, proven known layouts. Mixed append-only/legacy state, malformed pointers, unexpected registration objects, or changed paths fail closed.
- Device-key/DPAPI state is never removed or modified.
- Every physical delete uses pinned native identities and never follows reparse points; no broad or recursive pathname deletion.
- Use RED -> GREEN, independent review per task, fresh full aggregate, and final whole-plan review.

---

### Task 1: Accept a proven v2.5.21 legacy lifecycle source

**Files:**

- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Test: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Test: `tests/persistence/InstalledLifecycleHarness.SelfTest.ps1`
- Report: `.superpowers/sdd/2026-09-02-v2522-legacy-upgrade-safe-reclamation/task-1-report.md`

**Interfaces:**

- Produces: `Get-CcodLegacyUpgradeCompatibilityContext -InstallRoot -ExistingPointer -ActiveValidation -GlobalTransaction`
- Returns only `CurrentReady` or `ProvenLegacyWithoutReady`, with exact active runtime/generation/version/manifest identity.

- [ ] **Step 1: Write a real legacy RED fixture**

Build a fixture from merge-base `19803a79af3302c49f129e6a6b3ff7ffaf1b930b`: schema-2 `active.json`, v2.5.21 runtime/manifest and mutable legacy activation receipt, but no `state\active-generation`, `state\install-transactions`, or product cleanup fence plane. Invoke the actual v2.5.22 install path with lower OS effects adapted. Current code must fail before generation staging because it passes null Ready to the cleanup resolver.

Also add mixed-state negatives: append-only selector without transaction chain, fence plane without Ready, malformed legacy active pointer, wrong manifest version, and legacy path reparse.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Expected: nonzero at the true legacy fixture before the compatibility function exists; no adapter/setup failure.

- [ ] **Step 3: Implement exact compatibility classification**

For a current append-only installation, retain the full Ready/fence pre-upgrade resolution. For a proven legacy installation only, require all append-only/fence planes absent, exact schema-2 `active.json`, manifest-bound active runtime, project version `2.5.21` or another explicitly supported historical profile, and current-user safe paths. Skip durable-fence resolution because that version could not create such a fence. Any mixed or ambiguous state fails before staging.

- [ ] **Step 4: Run GREEN**

Run Lifecycle and InstalledLifecycleHarness suites; assert a new append-only selector/Ready transaction is produced, old active state remains only as legacy evidence, and failure before new Ready still restarts the old runtime.

- [ ] **Step 5: Commit/report**

Commit message: `fix: bridge legacy lifecycle upgrade`. Record RED/GREEN and no-real-action evidence.

### Task 2: Migrate exact historical registration profiles

**Files:**

- Modify: `src/persistence/modules/ProductRegistration.psm1`
- Test: `tests/persistence/ProductRegistration.SelfTest.ps1`
- Test: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Report: `.superpowers/sdd/2026-09-02-v2522-legacy-upgrade-safe-reclamation/task-2-report.md`

**Interfaces:**

- Produces: `Get-CcodLegacyRegistrationProfiles` and `Resolve-CcodLegacyRegistrationProfile -LegacyRegistration`.
- Each profile has canonical AppId, exact Start-menu/Desktop relative names, expected uninstall-command shape, and version range.

- [ ] **Step 1: Write profile REDs**

Use the exact v2.5.21 Inno shape:

```text
Programs\CodexRemote-fix\CodexRemote-fix.lnk
Programs\CodexRemote-fix\CodexRemote-fix compatibility check.lnk
Programs\CodexRemote-fix\Uninstall CodexRemote-fix.lnk
Desktop\CodexRemote-fix.lnk
```

Add exact older profile(s) supported by checked-in installer history. Prove current union-of-eight logic rejects the real v2.5.21 set. Reject missing/extra/cross-profile/case-varied/reparse entries and a registry version/uninstall command that does not match the selected profile.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
```

Expected: real v2.5.21 shape fails before profile implementation.

- [ ] **Step 3: Implement profile resolution and dynamic snapshot count**

Select exactly one complete profile; never require the union of historical names. Snapshot count is one registry entry plus the selected profile's shortcut count. Preserve reverse-order compensation, replacement no-overwrite, unresolved create-only records, and exact current registration proof.

- [ ] **Step 4: Run GREEN**

Run ProductRegistration and Lifecycle suites. The true legacy lifecycle fixture must complete new product registration and remove exactly the matching old profile; a second same-package invocation is idempotent.

- [ ] **Step 5: Commit/report**

Commit message: `fix: migrate exact legacy registration profiles`.

### Task 3: Reclaim a selected generation through pinned handles

**Files:**

- Create: `src/persistence/modules/GenerationReclamation.psm1`
- Modify: `src/persistence/InstalledUninstallFinalizer.ps1`
- Modify: `src/persistence/UninstallBootstrap.ps1`
- Test: `tests/persistence/UninstallBootstrap.SelfTest.ps1`
- Test: `tests/persistence/InstallFileTransaction.SelfTest.ps1`
- Report: `.superpowers/sdd/2026-09-02-v2522-legacy-upgrade-safe-reclamation/task-3-report.md`

**Interfaces:**

```powershell
Remove-CcodVerifiedGenerationTree -InstallRoot <absolute> -RuntimeRoot <exact selected leaf> -RuntimeId <id> -ExpectedManifestSha256 <64hex>
```

- [ ] **Step 1: Write deletion REDs**

Use a disposable generation with nested directories and manifest files. Insert a reparse child, hardlink, ADS, unexpected file, identity replacement, and an open child between initial validation and reclaim. Current pathname `Remove-Item -Recurse` must be shown to lack a pinned proof; hostile cases must delete neither the selected root nor outside target.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
```

- [ ] **Step 3: Implement bounded native reclamation**

Open the exact selected root and every expected manifest file/directory through relative native handles with DELETE/read-attributes/list rights and no delete/write sharing. Revalidate final paths, root ancestry, volume/file IDs, non-reparse, default stream, and single-link regular files. Compare the complete enumerated tree against the sealed manifest. Hold every handle, mark leaves and directories for deletion bottom-up through native handle disposition, then close. Any mismatch/open handle/change fails before deletion; never follow a path or use recursive `Remove-Item`. Preserve install root, sibling generations, state, and device-key store.

- [ ] **Step 4: Run GREEN**

Run UninstallBootstrap, IFT, Lifecycle, parser/diff and the full aggregate. The exact selected generation is absent only after handle-pinned deletion; sibling/root/state remain.

- [ ] **Step 5: Commit/report**

Commit message: `fix: reclaim generation through pinned handles`.

## Final verification

Run all focused persistence suites, `tests\PersistenceSelfTest.ps1`, parser/diff, and a fresh whole-plan review. Tasks 5–8 of the original release plan remain blocked until this plan is clean.

## Self-Review

- Spec coverage: Task 1 handles true lifecycle state; Task 2 handles actual installer registration; Task 3 handles physical reclamation.
- Placeholder scan: each task has concrete fixtures, APIs, commands and failure boundaries.
- Type consistency: Task 2 consumes Task 1's real legacy fixture; Task 3 is independent and preserves all lifecycle state.

