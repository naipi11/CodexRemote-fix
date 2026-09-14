# v2.5.22 Cross-Process Retry Closure Plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` and `superpowers:test-driven-development`. This is a successor to the failed final scoped review of `6b9bc7e..58db6fd`; it is not a second fix wave of the prior plan.

**Goal:** Make the two remaining public retry boundaries converge after a new Windows logon session or a process crash: installed `TaskRemoved` recovery before the external anchor exists, and legacy product migration after one or both overlapping shortcuts have already been replaced.

**Architecture:** The installed-uninstall path gets a narrowly scoped same-SID TaskRemoved matcher that revalidates the current runtime under the existing Local-to-Global lock order while preserving the historical session as evidence. Legacy migration gets a create-only, Ready-bound durable plan written before any current product write; later processes may consume that plan only when every immutable identity matches and each overlap is either the captured historical leaf or the exact current replacement.

**Constraints:** Work only in the existing worktree. No real registry, shortcut, scheduled task, installer, installation, uninstall, process restart, reboot, network, push, tag, release, or publication. Keep device-key/DPAPI state untouched. Do not weaken ordinary fresh-context session matching or accept a live hybrid legacy profile without a previously durable exact plan.

## Task 1 — Recover TaskRemoved from the same SID in a new session

**Files:**

- Modify: `src/persistence/UninstallBootstrap.ps1`
- Modify only if the public command shape must change: `Uninstall-CodexControlOtherDevices.ps1`, `src/persistence/InstalledUninstallFinalizer.ps1`
- Test: `tests/persistence/UninstallBootstrap.SelfTest.ps1`

1. Add a production-shaped RED in which the durable transaction is session 1, `ValidateInvocation` returns the same SID in session 99, phase is exact `TaskRemoved`, no staged recovery registry exists yet, and the public runtime wrapper supplies an exact new identity. Current code must fail at the generic context matcher.
2. Add a dedicated installed TaskRemoved matcher. It may ignore only the context session ID, and only after Local uninstall then Global `AccountTransition` acquisition and a fresh runtime/selector/Ready/manifest/epoch validation. Require the same SID, transaction ID, runtime ID, generation, epoch, Ready evidence, payload records, staged paths/hashes, and immutable installed binding. Preserve `transaction.sessionId` and historical `wrapper*`; write only exact `resumeWrapper*`, then persist/read back the transaction and receipt.
3. Directly return the verified existing TaskRemoved transaction; never call `RunCleanup` again. Launch `-WrapperResume` with the new wrapper identity and require its exact exit before reclamation. Ordinary pre-TaskRemoved resume and different-SID/runtime/generation/epoch/Ready/payload cases remain rejected.
4. Cover finalizer-start failure followed by a same-SID new-session second public invocation, plus session/PID/creation-time mutations. Run UninstallBootstrap and parser/diff checks.

## Task 2 — Persist and replay the exact legacy migration plan

**Files:**

- Modify: `src/persistence/modules/ProductRegistration.psm1`
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify if a private capability is required: `src/persistence/modules/InstallFileTransaction.psm1`
- Test: `tests/persistence/ProductRegistration.SelfTest.ps1`
- Test: `tests/persistence/InstallLifecycle.SelfTest.ps1`

1. Add REDs that use production-shaped shortcut evidence. Persist no in-memory object across attempts. Fail after Start-menu replacement, after Desktop replacement, and after current read-back. A real second registration attempt must currently fail to recapture the historical profile.
2. Before any current registry or shortcut write, publish a create-only durable migration-plan record through the product file transaction. Bind its canonical schema and leaf to the exact Ready transaction, runtime ID, generation, manifest SHA-256, package SHA-256, AppId, historical profile, registry values/kinds, and every shortcut path/bytes/hash/target/arguments/working directory. Bound sizes, duplicate-free JSON, safe ancestry, no reparse/ADS/multilink, exact ACL/owner, and create-only conflict semantics are mandatory.
3. On a later process, an existing exact plan may be reused only after its full binding is re-read and verified. Legacy registry and legacy-only entries must remain exact. Each overlap must independently be either the captured historical leaf or the exact current replacement for this same Ready/package. Missing/foreign overlap without an existing exact plan remains a zero-current-write failure.
4. Make current registration and legacy-only cleanup idempotently converge from historical/historical, current/historical, historical/current, and current/current overlap states. Preserve replacement-safe registry compensation and leave the durable plan append-only as audit evidence.
5. Add negative tests for absent/tampered/wrong-Ready/wrong-package/wrong-generation/duplicate/unsafe plan records and foreign hybrid leaves. Run ProductRegistration, InstallLifecycle, IFT when touched, parser/diff, and the full aggregate.

## Final gate

Freeze source, run ProductRegistration, UninstallBootstrap, InstallLifecycle, InstallFileTransaction, RuntimeManifest, InstalledLifecycleHarness, Bootstrap, ManualWrappers, all changed parsers, `git diff --check`, and `tests\PersistenceSelfTest.ps1`. Commit implementation and evidence separately. Then request one fresh scoped review of this successor range. Tasks 5–8 remain blocked until that review is clean.
