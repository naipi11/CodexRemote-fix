# SDD ledger — cross-process retry closure

Plan: `docs/superpowers/plans/2026-09-03-v2522-cross-process-retry-closure.md`

## Review provenance

- Prior implementation: `58db6fd`; evidence: `ea86451`.
- Prior plan's only final scoped review: FAIL, 1 Critical + 1 Important.
- Critical: generic context matching rejects same-SID new-session `TaskRemoved` before replacement-wrapper persistence.
- Important: legacy pre-capture plan is memory-only and cannot survive a partial current overlap write.

## Rulings

- Session relaxation is allowed only for exact installed `TaskRemoved`/`Failed(resumePhase=TaskRemoved)` after locked fresh proof. Cost if wrong: a foreign or stale runtime can adopt an uninstall transaction.
- A live current/historical hybrid is never authority by itself. It is acceptable only when a previously create-only durable plan proves the original complete historical layout and the current leaf matches the same Ready/package. Cost if wrong: the original wash-before-proof defect returns.
- The durable plan is append-only audit state; it is not deleted on success and never contains device-key material.

## Status

Task 1: complete. Initial implementation/evidence `9973bfd..bf4d215`; fix round 1 implementation/evidence `bf939c6..6107151`. Fix-round scoped re-review: Spec Compliance PASS, Task Quality PASS, 0 Critical, 0 Important. Final focused evidence: UninstallBootstrap 45/45, ManualWrappers pass, parser 2/2, `git diff --check` exit 0. No real system action.

Task 2: initial implementation `148f6ee`, evidence `66a91aa`; scoped review FAIL (0 Critical, 3 Important).
Fix round 1 implementation `a0c8d71`; evidence is recorded by the commit containing the corrected
`task-2-fix1-brief.md`, updated `task-2-report.md`, and this ledger. Fix round 1 closes crash-safe
fixed-directory ACL normalization/registered-handle cleanup, exact six-field profile and raw-path schema,
independent `powershell.exe` replay, and published-write/read-back failure convergence. Final focused evidence:
InstallFileTransaction 44 groups, ProductRegistration 30/30, InstallLifecycle 151/151, parser 4/4, and
`git diff --check` exit 0. No real system action.

Fix round 1 frozen gate: complete, including UninstallBootstrap 45/45, RuntimeManifest 21 groups,
InstalledLifecycleHarness 21 groups, Bootstrap 26/26, ManualWrappers 12 groups, and
`tests\PersistenceSelfTest.ps1` exit 0. Fix-round scoped re-review: Spec Compliance PASS, Task Quality PASS,
0 Critical, 0 Important. Task 2 is complete. Successor whole-plan final review remains pending; Tasks 5–8
remain blocked.
