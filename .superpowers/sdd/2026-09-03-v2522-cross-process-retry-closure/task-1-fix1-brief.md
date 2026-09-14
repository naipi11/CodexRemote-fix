# Task 1 fix round 1 — failed TaskRemoved and durable freshness

Read the Task 1 report and scoped review. Fix all four findings together; do not start Task 2.

## Required RED -> GREEN

1. Treat exact `Failed(resumePhase=TaskRemoved)` with an installed binding as the same narrowly authorized replacement-wrapper recovery profile as `TaskRemoved`. Under the existing Local uninstall -> Global AccountTransition order, revalidate fresh context and every immutable field, normalize back to TaskRemoved, persist the new wrapper binding, and return without `RunCleanup`. Same-session and new-session tests must prove zero application removal. All other Failed resume phases remain strict.
2. Give each replacement-wrapper persistence a fresh canonical `updatedAtUtc` strictly later than the prior transaction, clear the error, and make the TaskRemoved receipt bind that timestamp. Reject an old receipt, null/empty error-code ambiguity, write no-op, write failure, stale read-back, or malformed read-back. A retry after an interrupted replacement write must converge without changing historical evidence.
3. Require historical `wrapperUserSid == transaction.userSid` and `wrapperSessionId == transaction.sessionId` before any replacement write. Add zero-write negatives for both mutations.
4. Add a production-shaped/disk-backed test that obtains selector/Ready/manifest/epoch/payload evidence through the real verified-runtime path, changes only the current-session seam, and uses real atomic transaction/receipt storage with independent deserialized objects. Adapter-only tests may remain for fault injection but cannot be the sole proof.

Run UninstallBootstrap, ManualWrappers, changed parsers and `git diff --check`. Commit implementation and evidence separately, update the ledger/report, leave a clean tree, and request a scoped re-review. No real system/external actions and no release claim.
