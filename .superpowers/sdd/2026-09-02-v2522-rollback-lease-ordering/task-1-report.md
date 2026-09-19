# Task 1 report: release rollback cleanup lease before bootstrap

## Scope and commit

- Plan base: `3ec2a3d13f67995018b104840d121a6fadd2dcbd`.
- Implementation: `a178f01a69a622ac9bd20091d6fdb326132dd9b3`
  (`fix: release rollback cleanup lease`).
- The implementation commit contains only:
  - `src/persistence/modules/InstallLifecycle.psm1`
  - `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Evidence is recorded in this report and committed separately after the
  implementation source freeze.

This is the minimal follow-up for the rollback lease-ordering residual. It does
not claim release readiness, installed-product acceptance, or whole-branch
review completion.

## Root cause

An upgrade acquires `upgradeProductCleanupLease` as the outer real
`AccountTransition` mutex acquisition before resolving old durable product
cleanup. On a failure before selector commit, rollback released lifecycle
ownership and the inner install lease, but then called `StartSupervisorTask`
while the outer acquisition was still live. The scheduled-task bootstrap needs
the same real account mutex. It therefore timed out before it could restore and
prove the retained old runtime Ready. The recoverable original activation
failure was incorrectly escalated to `CCOD_INSTALL_ROLLBACK_FAILED`.

## Test-first cross-process proof

The new regression creates a temporary old Ready installation, mutates the
source payload to begin a real upgrade, and injects failure in the
`SetActiveRuntime` adapter before the production pointer write. It then proves:

- the real selector still names the old runtime at generation 1;
- exact old Supervisor exit occurred before rollback;
- rollback invoked the fake scheduled-task start boundary;
- that boundary launched a hidden, bounded independent `powershell.exe` child;
- the child obtained its SID from `WindowsIdentity.GetCurrent()` and imported
  the production `KernelObjects.psm1`;
- the child called production `Enter-CcodMutex -Kind AccountTransition` with a
  1500 ms mutex timeout;
- `attempted.txt` was written immediately before that real acquisition, while
  `acquired.txt` was written only after the returned lease had exact
  `Outcome='Acquired'`;
- the parent process wait was independently bounded at 10000 ms;
- rollback readiness could become `Ready` only for the retained old runtime,
  generation 1, after the real acquired marker existed.

No fake mutex or pre-call acquisition marker is used. The process helper is
test-only and does not create or start a Windows Scheduled Task.

## RED evidence

### Clean baseline before the test

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

- Exit: `0`.
- Result: `Install lifecycle self-tests passed: 128`.

### Test-only change against the old production module

The same complete command was run after adding only the cross-process helper
and rollback regression, before modifying production code.

- Exit: `1`.
- Harness result:

```text
CCOD_SELFTEST_FAILED case=pre-pointer-rollback-releases-the-outer-cleanup-lease-before-old-Supervisor-bootstrap error=ASSERT_TRUE
```

- Exact failing assertion:

```text
ASSERT_TRUE: old bootstrap acquires AccountTransition before readiness (childExit=42; outcome=TimedOut; childFailure=)
```

The preceding pointer, previous-protection-stopped, and bootstrap-attempted
assertions passed. The child completed normally enough to return the production
mutex outcome `TimedOut`; there was no adapter, parser, process-launch, or child
setup failure. This is the intended behavioral RED.

## Implementation and exact ordering

The pre-selector rollback branch now performs the following order:

1. Close the shutdown gate if it is still live.
2. Release live lifecycle ownership and require exact release proof.
3. Release the acquired install lease and require a literal Boolean `true`.
4. Release `upgradeProductCleanupLease` with
   `Exit-CcodLifecycleProductCleanupLease`.
5. Require a literal Boolean `true` and
   `upgradeProductCleanupLease.Lease.Released=true`.
6. Only after that proof, set `upgradeProductCleanupLease=$null`.
7. Read the rollback clock, invoke `StartSupervisorTask`, and wait for the old
   runtime readiness proof.

This is strict LIFO for the nested lifecycle, install, and outer product
cleanup acquisitions. If outer release throws or its exact result is not
proven, control leaves the rollback body before task start; the existing
rollback boundary normalizes the outcome to stable
`CCOD_INSTALL_ROLLBACK_FAILED`.

The successful forward-install path is unchanged. It still retains the outer
product-cleanup lease across old-Pending resolution and the new selector
commit, then releases lifecycle ownership, the install lease, and the outer
lease before starting the new runtime. The fix therefore does not reopen the
old-Pending/new-selector race.

The enclosing `finally` now retries outer cleanup only when the context, its
lease, and a still-unreleased lease are all present. A successful rollback
release nulls the caller variable, and an already-released non-null context is
also excluded, so final cleanup cannot release the mutex twice.

## GREEN evidence

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

- Exit: `0`.
- Result: `Install lifecycle self-tests passed: 129`.
- The new case proved `PointerCommitted=false`,
  `PreviousProtectionStopped=true`, `BootstrapAttempted=true`,
  `BootstrapMutexAcquired=true`, and `OldRuntimeOutcome='Ready'`.
- After successful rollback, the original injected pre-pointer failure remained
  `CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN`; it was not replaced by a false
  rollback-fatal code.
- The run retained the existing fresh-process observation:
  `CCOD_CROSS_PROCESS_OBSERVED exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`.

## Fresh final matrix after source freeze

| Command | Exit | Result |
|---|---:|---|
| `tests\persistence\InstallLifecycle.SelfTest.ps1` | 0 | `Install lifecycle self-tests passed: 129`. |
| `tests\persistence\KernelObjects.SelfTest.ps1` | 0 | 16 named cases, all `True`. |
| `tests\persistence\InstallFileTransaction.SelfTest.ps1` | 0 | `Install file transaction self-test passed.` |
| PowerShell parser over both changed PowerShell files | 0 | `PARSE_OK`; token counts 31424 and 40901. |
| `git diff --check` | 0 | No whitespace errors; only checkout LF-to-CRLF warnings. |
| `tests\PersistenceSelfTest.ps1` | 0 | Fresh tracked aggregate over 39 discovered `*.SelfTest.ps1` files; no failure output. |

The aggregate intentionally captures child self-test output and emits only a
stable failure line when a child exits nonzero, so empty aggregate stdout with
exit `0` is its normal passing result.

The focused and aggregate runs retain the prior real cross-process product
fence, bind-failure abort, abrupt-writer crash temporary recovery, atomic
`SignalAndWait`, stale-N and closed-N rejection, exact create-only histories,
and wrong-thread/double-cleanup mutex tests. No test was removed, skipped, or
target-filtered for the final matrix.

## No-real-action statement

No real scheduled task, installed product, registry, Start-menu/Desktop
shortcut, installer, uninstaller, Codex/product process, network, push, tag,
release, signing, publication, installation, restart, or reboot action was
performed. Tests used temporary fixture directories, fake task/product
adapters, hidden bounded test child processes, and private named mutex/event
objects only.

## Remaining review boundary

Request a fresh task and whole-branch independent review of the implementation
and evidence commits. In particular, re-check the pre-selector rollback order,
the unchanged post-selector success protection, release-failure normalization,
and final live-lease guard. The green focused matrix and aggregate are not
installed Windows acceptance, Defender evidence, reboot acceptance, or release
proof.
