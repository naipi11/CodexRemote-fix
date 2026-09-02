# SDD ledger — plan: docs/superpowers/plans/2026-09-02-v2522-legacy-upgrade-safe-reclamation.md

## Preflight interface scan

| Producer task | Consumer task | Shared interface | Finding | Ruling |
|---|---|---|---|---|
| Task 1 | Task 2 | True v2.5.21 active.json/no-transaction fixture | Product migration tests must consume the real legacy shape, not a current-format Ready disguised as old. | Ruling: Task 1 fixture is the source of truth for Task 2 integration. Cost if wrong: old installations pass tests but fail before staging or at registration. |
| Task 1 | Task 1 | Durable cleanup resolver | A real legacy version cannot have a cleanup fence or Ready transaction. | Ruling: skip resolver only after proving every append-only/fence plane absent and exact legacy active runtime valid; mixed state fails closed. Cost if wrong: malformed current installs bypass cleanup. |
| Task 2 | Task 2 | Historical shortcut profiles | Requiring the union of every historical name is impossible. | Ruling: match one exact checked-in installer profile and dynamic snapshot count. Cost if wrong: legitimate v2.5.21 upgrades never converge or foreign shortcuts are deleted. |
| Task 3 | Task 3 | Installed finalizer reclamation | Path validation before recursive Remove-Item is not bound to deletion. | Ruling: hold exact native handles for the complete manifest tree and delete bottom-up by handle only. Cost if wrong: concurrent path changes can redirect or invalidate deletion. |

## Status

Task 1: in progress. Broad whole-branch review found one Critical true-legacy upgrade blocker and two independent Important production defects.

Task 1 fix round 1 Ruling: support two exact append-only retry profiles. A pre-pointer failure has latest selector generation 1 on the legacy runtime and may converge by appending generation 2 to the retained new runtime. A post-pointer compensated failure has canonical `1 old -> 2 new -> 3 old` and may converge only by appending generation 4 back to the same retained new runtime. Never delete or rewrite selector history. Cost if wrong: a transient post-pointer failure either becomes unrecoverable or corrupts the monotonic selector chain.

Task 1: fix round 1/5 (1 addressed, 0 open; legacy migration retry after pre/post pointer failure; commits 812b34e..4504c1a).

Task 1: complete (commits 2aef5ff..4504c1a, scoped re-review clean: Spec Compliance PASS, Task Quality PASS).

Task 2: in progress. Consumes Task 1 true v2.5.21 fixture and replaces the impossible union-of-history shortcut requirement with exact installer profiles.

Task 2: fix round 1/5 (1 addressed, 0 open; registry compensation replacement overwrite; commits be47fad..3682b81).

Task 2: complete (commits 4504c1a..3682b81, scoped re-review clean: Spec Compliance PASS, Task Quality PASS).

Task 3: in progress. Replace pathname recursive generation deletion with manifest-complete, handle-pinned native reclamation.

Task 3 Ruling: Windows rejects delete disposition on a nonempty directory even when every child is already pinned/armed. Use a two-phase protocol: fully pin/revalidate the exact tree; arm every file while reversible and disarm all on any file-mark failure; only after all file marks succeed enter the irreversible commit, close files, then mark/close directories deepest-first and the selected root last. Cost if wrong: a post-commit filesystem failure can leave a partially reclaimed selected tree, but all affected identities remain inside the fully pinned selected generation and no sibling/outside path can be reached.

Task 1: fix round 1/5 (1 addressed, 0 open; exact pre/post pointer legacy migration retry; commits 812b34e..4504c1a).

Task 1: complete (commits 2aef5ff..4504c1a, scoped re-review clean: Spec Compliance PASS, Task Quality PASS).

Task 2: fix round 1/5 (1 addressed, 0 open; registry replacement-safe compensation; commits be47fad..3682b81).

Task 2: complete (commits 4504c1a..3682b81, scoped re-review clean: Spec Compliance PASS, Task Quality PASS).

Task 3: complete (commits 3682b81..6b9bc7e, task review clean: Spec Compliance PASS, Task Quality PASS).

Final whole-plan review: FAIL (0 Critical, 3 Important): compensated selector may lack PointerCommitted journal evidence; legacy overlap proof occurs after current overwrite; irreversible reclamation has no durable tail resume. One final fix wave permitted.

Final fix wave: implementation complete at `58db6fd` (3 original Important addressed in one wave). Final frozen verification: ProductRegistration 24, InstallLifecycle 150, UninstallBootstrap 37, InstallFileTransaction 37, RuntimeManifest 21, InstalledLifecycleHarness 21, Bootstrap 26, ManualWrappers pass; all modified PowerShell parsers 0 errors; `git diff --check` and full `tests\PersistenceSelfTest.ps1` exit 0. Scoped re-review of `6b9bc7e..58db6fd` remains pending; Tasks 5–8 and release readiness remain blocked.
