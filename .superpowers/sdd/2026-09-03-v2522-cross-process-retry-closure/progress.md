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

Task 1: initial implementation `9973bfd`, evidence `bf4d215`; scoped review FAIL (1 Critical, 3 Important). Fix round 1 is in progress. Required closure: include `Failed(resumePhase=TaskRemoved)` in the exact early-return state; make replacement persistence and receipt fresh; require historical wrapper SID/session consistency; replace aliasing test doubles with serialized/disk-backed read-back and failure negatives.

Task 2: pending.

Final gate and fresh scoped review: pending. Tasks 5–8 remain blocked.
