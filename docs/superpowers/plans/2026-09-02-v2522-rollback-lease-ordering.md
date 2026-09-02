# Rollback Lease Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every pre-selector upgrade rollback releases the outer product-cleanup AccountTransition acquisition before scheduled-task bootstrap restarts and proves the old Supervisor.

**Architecture:** Treat `upgradeProductCleanupLease` as the outermost reentrant AccountTransition acquisition. On failure after old protection stops but before the new selector commits, release inner lifecycle/install acquisitions and then the outer product-cleanup acquisition in strict LIFO order before `StartSupervisorTask`. Clear the variable only after exact release so the finalizer is idempotent and cannot double-release.

**Tech Stack:** Windows PowerShell, existing KernelObjects AccountTransition mutex, InstallLifecycle adapters and self-tests.

**Spec:** `docs/superpowers/specs/2026-08-29-v2522-immutable-generation-design.md`

## Global Constraints

- Work only in the existing isolated branch/worktree.
- No real product, registry, shortcut, scheduled task, installer, network, publication, installation, restart, or reboot action.
- Do not change fence schemas, selector formats, Ready identity, or IFT native file behavior.
- A pre-selector failure must leave the old selector/runtime authoritative; rollback restart must run only after all AccountTransition acquisitions owned by the installer are released.
- Release order is LIFO, release result must be proved, and final cleanup must not double-release.
- Use RED -> GREEN, focused lifecycle/Kernel tests, parser/diff, full aggregate, and independent review.

---

### Task 1: Release outer product-cleanup lease before rollback restart

**Files:**

- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Test: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Report: `.superpowers/sdd/2026-09-02-v2522-rollback-lease-ordering/task-1-report.md`

**Interfaces:**

- Consumes: `upgradeProductCleanupLease`, `Exit-CcodLifecycleProductCleanupLease`, lifecycle ownership/install lease release, `StartSupervisorTask`, `WaitNewRuntimeReady`.
- Produces: helper `Exit-CcodUpgradeProductCleanupLeaseForRollback` or equivalent single call site that validates exact release, sets the caller variable to null only after success, and runs before old Supervisor restart.

- [ ] **Step 1: Write the failing real-mutex rollback test**

Create a temporary old Ready installation and begin a real upgrade. Inject failure at `SetActiveRuntime` before selector commit after old protection has stopped. The rollback path must use a real `AccountTransition` mutex for the outer product-cleanup lease. Its fake scheduled-task bootstrap child must attempt the same real mutex atomically and write a marker only after acquisition. Current code should time out/fail because the installer still holds the outer lease.

Assertions:

```powershell
Assert-CcodEqual $false $world.PointerCommitted 'failure occurs before selector commit'
Assert-CcodTrue $world.PreviousProtectionStopped 'old protection was stopped'
Assert-CcodTrue $world.BootstrapAttempted 'rollback attempted old Supervisor bootstrap'
Assert-CcodTrue $world.BootstrapMutexAcquired 'old bootstrap acquires AccountTransition before readiness'
Assert-CcodEqual 'Ready' $world.OldRuntimeOutcome 'old runtime is restored and proven ready'
```

- [ ] **Step 2: Run RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Expected: nonzero exit at the bootstrap mutex-acquired/rollback-ready assertion. An adapter setup error, fake mutex, or pre-call marker is not valid RED evidence.

- [ ] **Step 3: Implement exact LIFO release**

After lifecycle ownership and install lease are released, but before `StartSupervisorTask`, release the live `upgradeProductCleanupLease` with `Exit-CcodLifecycleProductCleanupLease`. Require a true result and `Lease.Released=true`; then set `upgradeProductCleanupLease=$null`. If release fails, throw stable rollback failure without starting the task. The enclosing finally checks null/live state and must not release twice.

Do not release this outer lease early on successful forward installation; it must continue protecting old-Pending resolution through selector commit.

- [ ] **Step 4: Run GREEN and regression matrix**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\KernelObjects.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
git diff --check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1
```

Parse both changed PowerShell files. Also retain cross-process fence, bind-abort, crash-temp, atomic SignalAndWait, stale-N, and closed-N tests through the aggregate.

- [ ] **Step 5: Commit and report**

```powershell
git add src/persistence/modules/InstallLifecycle.psm1 tests/persistence/InstallLifecycle.SelfTest.ps1
git commit -m "fix: release rollback cleanup lease"
```

Write the report with exact RED/GREEN output, release ordering, no-real-action statement, implementation SHA, and full aggregate result. Commit evidence separately and request a fresh task plus whole-branch review.

## Self-Review

- Spec coverage: one task covers the single load-bearing residual and all regression gates.
- Placeholder scan: no TODO/TBD; exact failure injection, assertions, implementation boundary, and commands are present.
- Type consistency: the same `upgradeProductCleanupLease` created by durable cleanup is released with the existing exact function before bootstrap.

## Execution Handoff

The user requested continued execution. Use subagent-driven development with a fresh implementer and independent reviewer.

