# Durable Product Cleanup Fence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make post-Ready product-transaction cleanup fail closed across processes, so no installation can report verified product registration while a prior strict product transaction remains unresolved.

**Architecture:** A product registration attempt obtains the existing account transition lease, writes an exact durable cleanup fence while that lease is held, then closes its strict product transaction. Completion is recorded durably before the fence is released; close failure leaves a durable pending record that blocks other processes from reconciling or reporting success until the original owner resolves it or a proven-dead owner is safely recovered. The existing `SignalAndWait` test protocol remains test-only and proves an actual wait on the real mutex.

**Tech Stack:** Windows PowerShell, .NET named mutex/event primitives, native V4 install file transaction runtime, append-only state records, existing persistence self-tests.

**Spec:** `docs/superpowers/specs/2026-08-29-v2522-immutable-generation-design.md`

## Global Constraints

- Work only in `codex/v2522-install-runtime-reliability`; do not alter `main`.
- No real registry, shortcut, installer, uninstaller, product process, network, release, tag, signing, push, publication, installation, or reboot action.
- All cleanup identity is exact: canonical install root, full Ready transaction identity, runtime ID/generation, manifest/package hashes, owner PID/creation time/SID, and account transition lease.
- State records are append-only/create-only, reject duplicate/extra fields and unsafe path objects, and never overwrite a replacement.
- A failure after lifecycle `Ready` never appends lifecycle `Failed`, never rolls back the selected generation, and never returns a verified product-registration receipt.
- Cross-process recovery may not transfer a thread-bound mutex lease. An owner still alive blocks reconciliation; a proven-dead owner may only be reconciled under a fresh real account-transition lease and exact Ready identity proof.
- Every production behavior change starts with an observed failing test; all claims require fresh focused suites, parser/diff checks, full aggregate, and independent review.

---

### Task 1: Durable cross-process product-cleanup fence

**Files:**

- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `src/persistence/modules/InstallFileTransaction.psm1`
- Test: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Test: `tests/persistence/InstallFileTransaction.SelfTest.ps1`
- Report: `.superpowers/sdd/2026-09-02-v2522-durable-product-cleanup/task-1-report.md`

**Interfaces:**

- Consumes: exact `Ready` install transaction (ordered 12-field lifecycle record), `AccountTransition` mutex, `Close-CcodInstallFileTransaction` retry contract.
- Produces:
  - `New-CcodLifecycleProductCleanupFence -InstallRoot -ReadyTransaction -OwnerIdentity`
  - `Resolve-CcodLifecycleProductCleanupFence -InstallRoot -ReadyTransaction -CurrentIdentity -CloseProductTransaction`
  - `Complete-CcodLifecycleProductCleanupFence -Fence -Outcome Completed|Pending`
  - a private test-only lower close seam whose default invokes the real native runtime close.

- [ ] **Step 1: Write failing cross-process cleanup tests**

Add a fixture that opens a real strict product transaction, injects one lower native-close failure while still executing the real lease-release path, and records a durable fence before the close call. Start a second PowerShell process that acquires the real `AccountTransition` mutex after the first close failure. Assert it sees the exact pending fence and exits `CCOD_PRODUCT_REGISTRATION_FAILED` without opening product authority, writing shortcuts, or returning `{ verified = true }`.

Add a same-process retry test that forces two close failures, verifies `Ready` remains and no `Failed` snapshot appears, then makes the lower close succeed. Its exact same-package `AlreadyInstalled` invocation must drain the original capability, append a completed fence record, and only then return verified registration.

```powershell
Assert-CcodThrows {
    Invoke-CcodInstall -InstallRoot $fixture.Install -SealedPackageSha256 $fixture.PackageHash -Adapters $firstFailureAdapters
} 'CCOD_PRODUCT_REGISTRATION_FAILED'
Assert-CcodEqual 'Ready' (Read-CcodInstallTransactionRecord -InstallRoot $fixture.Install).phase
Assert-CcodEqual 0 (Get-CcodFailedInstallSnapshotCount $fixture.Install)
Assert-CcodThrows {
    Invoke-CcodOtherProcessReconciliation -InstallRoot $fixture.Install -PackageHash $fixture.PackageHash
} 'CCOD_PRODUCT_REGISTRATION_FAILED'
```

- [ ] **Step 2: Run test to verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Expected: nonzero exit. The failure must show that the second process can currently proceed after the first product close fails, or that the durable fence API is absent. Do not accept an adapter-contract or test-harness failure as the RED.

- [ ] **Step 3: Implement durable fence and close ordering**

While an outer real `AccountTransition` lease is held, create a create-only durable record under the proven state plane before invoking strict product close. It contains only:

```powershell
[ordered]@{
    schemaVersion = 1
    transactionId = $ReadyTransaction.transactionId
    runtimeId = $ReadyTransaction.newRuntimeId
    runtimeGeneration = [uint64]$ReadyTransaction.newGeneration
    manifestSha256 = $ReadyTransaction.newManifestSha256
    packageSha256 = $ReadyTransaction.sealedPackageSha256
    ownerPid = [int]$OwnerIdentity.pid
    ownerCreationTimeUtc = [string]$OwnerIdentity.creationTimeUtc
    ownerSid = [string]$OwnerIdentity.userSid
    state = 'Pending'
}
```

Append a second create-only `Completed` record only after exact original close succeeds. Resolve the latest valid record under the same real account lease before opening authority:

- pending owner alive with matching PID/creation/SID: fail closed;
- pending owner proven dead: verify exact Ready/selected generation, reconcile under a fresh real account-transition lease, then append `Completed`;
- same owner/current thread: retry the retained original capability; never transfer its mutex lease.

Change `Close-CcodInstallFileTransaction` so a failed native runtime close cannot create a release-before-fence window. It may release an inner reentrant lease only while the outer durable-fence lease remains held. Preserve same-thread retry and return `CCOD_INSTALL_CLOSE_FAILED` on unresolved cleanup.

- [ ] **Step 4: Run focused GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
```

Expected: all existing cases plus cross-process pending-fence cases pass. Verify first failed close returns no verified receipt, other process opens no product authority, and exact retry returns `AlreadyInstalled` only after durable completion.

- [ ] **Step 5: Commit implementation and report**

```powershell
git add src/persistence/modules/InstallLifecycle.psm1 src/persistence/modules/InstallFileTransaction.psm1 tests/persistence/InstallLifecycle.SelfTest.ps1 tests/persistence/InstallFileTransaction.SelfTest.ps1
git commit -m "fix: fence durable product cleanup"
```

Write the report with exact RED output, GREEN commands/counts, cross-process proof, no-real-action statement, implementation SHA, and compatibility impact.

### Task 2: Atomic real-mutex proof and final Task 4 verification

**Files:**

- Modify: `tests/persistence/InstallFileTransaction.SelfTest.ps1`
- Test: `tests/persistence/KernelObjects.SelfTest.ps1`
- Test: `tests/PersistenceSelfTest.ps1`
- Report: `.superpowers/sdd/2026-09-02-v2522-durable-product-cleanup/task-2-report.md`

**Interfaces:**

- Consumes: `Enter-CcodLifecycleOwnership -Adapters`, real `Enter-CcodMutex -Kind AccountTransition`, Task 1 durable cleanup fence.
- Produces: an OS-level deterministic child wait proof that does not change production mutex code.

- [ ] **Step 1: Write atomic wait RED**

In the MTA child, use the `EnterMutex` adapter only to call real `Enter-CcodMutex` with a `WaitMutex` adapter that performs:

```powershell
[Threading.WaitHandle]::SignalAndWait($enteredActualWaitEvent, $mutexHandle, 15000, $false)
```

The parent holds real N product authority, waits for `enteredActualWaitEvent`, proves child cannot write acquired/commit record while N is open, opens N retained shortcut, closes N, then requires child to acquire/commit N+1. Temporary removal of N outer lease must fail at blocked assertion; restore it before GREEN.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
```

Expected: nonzero exit on blocked-after-atomic-wait assertion with temporary lease removal. It must not fail from STA, adapter loading, marker timing, or a mocked mutex.

- [ ] **Step 3: Preserve atomic protocol and mutex invariants**

Keep production `KernelObjects` unchanged unless a concrete failure proves it needs alteration. Child uses `-Mta`; real mutex creation, ACL, timeout, abandoned handling, and same-thread release remain default behavior. Assert stale N fails after N+1 and closed N cannot be reused.

- [ ] **Step 4: Run GREEN and full verification**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\KernelObjects.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
git diff --check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1
```

Parse every changed PowerShell file with `[System.Management.Automation.Language.Parser]::ParseFile`. All commands must exit zero after final source changes.

- [ ] **Step 5: Commit evidence and request independent review**

```powershell
git add tests/persistence/InstallFileTransaction.SelfTest.ps1 tests/persistence/KernelObjects.SelfTest.ps1 .superpowers/sdd/2026-09-02-v2522-durable-product-cleanup
git commit -m "docs: record durable cleanup fence evidence"
```

The report distinguishes temporary mutation RED from final GREEN, states full aggregate result, makes no release-readiness claim, and requests fresh independent review.

## Self-Review

- Spec coverage: Task 1 covers durable cross-process cleanup and no false receipt; Task 2 covers atomic actual-wait evidence and final verification.
- Placeholder scan: no TBD/TODO markers; every test command, record schema, and failure boundary is explicit.
- Type consistency: both tasks use the same ordered Ready transaction identity, `AccountTransition` mutex, and create-only fence records; Task 2 consumes Task 1 fence rather than a second cleanup source.

## Execution Handoff

The user requested continued execution. Execute this plan with subagent-driven development: one fresh implementer and independent review per task, then a final Task 4 review.

