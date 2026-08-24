# Task 2 report — lifecycle epoch and generation fence

## Status

Implemented the monotonic lifecycle ownership receipt and active-runtime generation migration.

- Added `LifecycleEpoch.psm1` with the exact exported ownership/fence surface.
- Stores the epoch in `state\lifecycle-epoch.json` outside immutable runtimes, with a durable initialization marker that prevents a first-write crash from reusing epoch one. It strictly validates unsigned numeric JSON, increments under the ACL-validated account transition mutex, atomically writes, and proves the read-back before returning ownership.
- Fences a caller on exact epoch, active runtime ID/generation, and PID plus creation time.
- Upgraded new active pointers to schema 2 and deterministically maps legacy schema-1 pointers to generation 1 before the next schema-2 commit.

## RED evidence

1. `LifecycleEpoch.SelfTest.ps1` initially failed at module import because `LifecycleEpoch.psm1` did not exist.
2. `RuntimeManifest.SelfTest.ps1` initially failed with `expected=[2] actual=[1]` after adding the schema-2 contract assertion.
3. The persisted-maximum regression initially failed because Windows PowerShell parses JSON `UInt64.MaxValue` as `Decimal` and the first strict conversion rejected it as invalid instead of reporting exhaustion.
4. The crash-before-active-pointer regression initially failed because an absent epoch could have been mistaken for first installation. The durable initialization marker now makes that state fail closed.

## GREEN evidence

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleEpoch.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\KernelObjects.SelfTest.ps1
```

All passed. The new epoch test exercises strict increments, stale owners, missing/corrupt numeric state, atomic write/read-back failures, abandoned leases, crash/reboot gaps, runtime rollback/generation mismatch, PID creation-time mismatch, idempotent release, the real current-user ACL mutex, and a persisted `UInt64.MaxValue`.

## Full-suite evidence

```text
npm run test:persistence
```

Passed with exit code 0 after the final precision fix.

## Self-review

- Kept Task 1's request-file mutex untouched; the new lifecycle epoch uses the existing KernelObjects account-transition mutex as its distinct ownership fence.
- Confirmed current `InstallLifecycle` persistence tests remain green without expanding this task into installer flow.
- No changes were needed in `KernelObjects.psm1`: it already validates the required current-user ACL and distinguishes abandoned mutex ownership; the new lifecycle integration test exercises that real boundary.

## Fix round 1 — 2026-08-23

### Review findings closed

- Bootstrap now reads schema-2 pointers, preserves their exact `UInt64` generation, and promotes only through a lifecycle owner created from the independently verified fallback runtime's exact manifest-bound `RuntimeManifest` and `LifecycleEpoch` modules. It retains the original verified KernelObjects module receipt until the outer launch lease is released. Healthy legacy active runtimes remain launchable without fence modules because they perform no pointer mutation.
- `Set-CcodActiveRuntime` now requires a lifecycle fence both before reading `active.json` and immediately before committing it. Initial creation additionally requires an unreleased generation-one owner for the exact new runtime. A race test changes the generation between those two proofs and confirms that the stale writer cannot reuse it.
- Both lifecycle epoch files are created atomically with a protected explicit current-user/SYSTEM/Administrators DACL, and both ACLs are proven on every read and after every write. The real Windows integration test independently checks owner, protection, rule count, principals, rights, inheritance, and access type.
- Exact integral `Decimal` values through `UInt64.MaxValue` are accepted; maximum is reported as generation/epoch exhaustion; fractional and exact out-of-range Decimal values are rejected.
- Existing installer and verified-runtime test fixtures were adapted only at the lifecycle/schema-2 boundary. Task 1's request-file mutex remains separate and unchanged.

### RED evidence

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleEpoch.SelfTest.ps1
ASSERT_THROWS: expected CCOD_LIFECYCLE_EPOCH_ACL_INVALID

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
ASSERT_THROWS: expected CCOD_RUNTIME_FENCE_STALE
```

The RuntimeManifest REDs separately proved that a released owner and a noninitial generation could create the first pointer. For the between-read-and-commit regression, temporarily removing only the second fence produced the same expected `ASSERT_THROWS` failure; restoring it returned the suite to green.

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
ASSERT_EXACT: healthy legacy active runtime launches without pointer mutation expected=[0] actual=[1]
```

The inherited bootstrap behavior tests also initially failed the fallback launch (`expected=[0] actual=[1]`) until the verified module lifetime and manifest fixture ordering were corrected.

### GREEN and full-suite evidence

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleEpoch.SelfTest.ps1
exit 0; 10 tests

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
exit 0; 14 tests

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\KernelObjects.SelfTest.ps1
exit 0; 16 tests

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
exit 0; Bootstrap self-test passed: 14

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
exit 0; Install lifecycle self-tests passed: 58

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SessionController.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\StaticProbeWorker.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UiActions.SelfTest.ps1
all exit 0

npm run test:persistence
exit 0
```

The final full run was executed after the last production change. Its only diagnostics were the suite's existing TrayHostClient unapproved-verb warnings; it reported no test failures.

### Files

- Production: `src/persistence/bootstrap.ps1`, `src/persistence/modules/InstallLifecycle.psm1`, `src/persistence/modules/LifecycleEpoch.psm1`, `src/persistence/modules/RuntimeManifest.psm1`.
- Primary tests: `tests/persistence/Bootstrap.SelfTest.ps1`, `tests/persistence/InstallLifecycle.SelfTest.ps1`, `tests/persistence/LifecycleEpoch.SelfTest.ps1`, `tests/persistence/RuntimeManifest.SelfTest.ps1`.
- Minimum caller-fixture compatibility: `tests/persistence/ManualWrappers.SelfTest.ps1`, `tests/persistence/SessionController.SelfTest.ps1`, `tests/persistence/StaticProbeWorker.SelfTest.ps1`, `tests/persistence/UiActions.SelfTest.ps1`.

### Self-review and concerns

- Pointer mutation remains available only through a proven lifecycle owner in production. Test-only callers that merely need a consumer fixture write literal schema-2 pointers instead of weakening production fencing.
- Bootstrap does not unload the verified fence modules before releasing the outer launch lease; the process exits immediately afterward, so no long-lived module-surface expansion remains.
- `KernelObjects.psm1` required no source edit: the existing account-transition mutex and ACL contract remained valid and its complete focused suite passed.
- No known correctness blocker remains. The report is under `.superpowers/sdd`, which is ignored by default, so it must be force-added with this task commit.

## Fix round 2 — required lifecycle-release propagation

### Finding closed

Bootstrap no longer suppresses `Exit-CcodLifecycleOwnership` failure after a ready fallback has promoted `active.json`. The cleanup now requires an exact Boolean success and the receipt's `released=true` mutation. A throw, false return, or unmutated receipt is normalized to `CCOD_BOOTSTRAP_FENCE_RELEASE_FAILED` and propagated through the outer bootstrap failure path. The current-process wrapper is still disposed through a nested `finally`.

This forces bootstrap to stop the ready child and exit instead of waiting on a long-lived Supervisor while one recursive account-transition mutex acquisition may remain owned. Process exit then lets Windows close the remaining handle ownership.

### RED evidence

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
ASSERT_EXACT: release failure exits instead of waiting for the ready long-lived Supervisor expected=[False] actual=[True]
exit 1
```

The behavior fixture uses a manifest-verified fallback runtime whose lifecycle module injects an `Exit-CcodLifecycleOwnership` failure after successful promotion. Its Supervisor signals the real Ready event and then sleeps for 60 seconds. Before the fix, the four-second bootstrap process bound expired because release failure was swallowed and bootstrap waited for that child.

### GREEN evidence

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
Bootstrap self-test passed: 15
exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleEpoch.SelfTest.ps1
exit 0; 10 tests

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
exit 0; 14 tests

npm run test:persistence
exit 0
```

The new bootstrap regression proves all of the following observable behavior:

- bootstrap exits nonzero before the four-second bound instead of waiting on the 60-second ready Supervisor;
- `bootstrap.log` contains `CCOD_BOOTSTRAP_FENCE_RELEASE_FAILED` and contains no successful fallback-readiness record;
- the outer failure cleanup stops the child;
- immediately after bootstrap exits, a fresh process can acquire and release the account-transition mutex, proving OS cleanup removed any remaining recursive ownership.

### Files and self-review

- Modified production: `src/persistence/bootstrap.ps1`.
- Modified focused test: `tests/persistence/Bootstrap.SelfTest.ps1`.
- Appended report: `.superpowers/sdd/2026-08-23-lifecycle-and-tray-redesign/task-2-report.md`.
- Successful fallback behavior remains unchanged and is covered by the existing schema-1/schema-2 promotion tests.
- No new production adapter or public interface was introduced. No known blocker remains.
