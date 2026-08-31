# Task 2 report: immutable lifecycle generations

## Status

Implemented the Task 2 immutable lifecycle migration in the assigned worktree.
The install path now stages a unique manifest-bound generation, appends the
transaction and active-generation chains, selects the generation bootstrap for
the scheduled task, retains legacy root shells and failed/old generations, and
uses a higher compensating pointer after post-pointer failure.

No release, push, tag, signing, build, installation, real product process
start/stop, WindowsApps access, DPAPI access, or external write was performed.

## RED evidence

- Recovery baseline command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `1` at `first-install-stages-verifies-activates-task-and-persists-consent`,
  old assertion `stable bootstrap copied`. The obsolete root-shell expectation
  was replaced by the approved generation-specific shell contract.
- Runtime identity RED exited `1` because `New-CcodUniqueRuntimeId` had no
  `ContentSha256` parameter. GREEN binds the full SHA-256 of
  `projectVersion + NUL + sealedPackageSha256` and a per-attempt nonce into a
  96-character runtime ID.
- Activation receipt RED exited `1` because `StartingProtection` wrote mutable
  `state\post-install-activation.json`. GREEN writes phase-specific create-only
  records below `state\activation-receipts` through the opaque transaction.
- Operational-state RED reproduced `UnauthorizedAccessException` and
  `CCOD_ATOMIC_REPLACE_FAILED` after the Task 1 record seal made status and UI
  files read-only. GREEN separates immutable initialization evidence below
  `state\install-initializations\<runtimeId>` from writable operational state
  materialized only when all operational leaves are absent.
- Real idempotence RED expected `AlreadyInstalled` but received `Upgraded`.
  GREEN performs no pointer, runtime, task, or process mutation only when the
  active Ready transaction has the exact explicitly supplied package identity;
  a different explicit identity returns `CCOD_INSTALL_PACKAGE_CONFLICT`.
- Bounded reader RED exited `1` because `Read-CcodStrictJson` had no
  `MaxBytes` parameter. GREEN rejects oversized records before JSON parsing.
- Transaction-chain identity RED exited `1` because a contiguous snapshot
  chain could change `oldRuntimeId`. GREEN binds every immutable transaction
  identity field across all snapshots.

## GREEN and verification evidence

- Lifecycle command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Lifecycle exit/result: `0`; `Install lifecycle self-tests passed: 108`.
- Runtime manifest command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1`
- Runtime manifest exit/result: `0`; 16 named cases passed.
- Uninstall bootstrap command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1`
- Uninstall bootstrap exit/result: `0`; `Uninstall bootstrap self-tests passed: 12`.
- Persistence I/O command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\PersistenceIO.SelfTest.ps1`
- Persistence I/O exit/result: `0`; 24 named cases passed.
- Aggregate command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
- Aggregate exit: `0` (`TASK2_AGGREGATE_EXIT=0`). The prior local
  Bootstrap/mutex boundary did not reproduce in this fresh run.
- Parser command: explicit
  `[Management.Automation.Language.Parser]::ParseFile` pass over all eight
  changed PowerShell code/test files.
- Parser exit: `0` (`TASK2_PARSER_EXIT=0`); every file reported `PARSER_OK`.
- Diff command: `git diff --check`
- Diff exit: `0` (`TASK2_DIFF_CHECK_EXIT=0`; checkout emitted only LF-to-CRLF
  warnings).

## Behavior and boundaries

- Runtime IDs are unique per attempt and retain a full deterministic digest of
  project version plus canonical sealed package identity. Runtime manifest
  validation still rejects runtime-ID, project-version, file-list, length, and
  content tampering.
- `state\active-generation\<20-digit>.json` is the only new active selector.
  New installs never write `active.json`; legacy `active.json` remains read-only
  migration input.
- Transaction snapshots have exact fields and types, strict positive integer
  generations, bounded safe reads, contiguous phases, immutable identity, and
  rejection for unknown objects, reparse points, ADS, multilinks, competing
  nonterminal chains, duplicate/gapped/post-terminal chains, and ambiguous
  terminal selection.
- Initial settings, status, verified packages, transition, and UI preference
  evidence is create-only and generation-bound. The operational state plane is
  separately created only when entirely absent and remains writable; the tests
  perform real StateStore and UI write/read round trips without changing file
  attributes.
- Pre-pointer failures retain the failed candidate and leave the old pointer
  and legacy root bootstrap/uninstaller bytes unchanged. Post-pointer failures
  either append a higher compensation pointer to the retained old runtime and
  prove it ready, or persist exactly
  `Failed/CCOD_INSTALL_ROLLBACK_FAILED`. Both generations remain retained.
- Stable shell candidates remain inside the immutable runtime generation. The
  scheduled-task adapter is updated only after pointer commit and targets that
  generation's bootstrap. There is no root shell overwrite or install-hot-path
  recursive runtime deletion.
- Idempotence/conflict decisions require an explicit canonical
  `SealedPackageSha256`. A legacy/direct call that omits it cannot claim package
  identity and follows the normal unique-generation path; Task 3 Setup must
  always pass the sealed package hash.
- Task 1 file-layer modules are imported lazily without `-Force` only when an
  immutable install operation is actually invoked. This preserves the staged
  uninstall module import closure and avoids rebinding a live Task 1
  transaction.

## Concerns

- The current-user ordinary-race boundary remains unchanged: this does not
  claim protection from an unrestricted same-user writer or in-process module
  introspection.
- The pre-Task-3 activation owner still consumes the legacy single receipt in
  its synthetic compatibility tests. Task 3 owns migration of the sealed Setup
  bootstrap/validator to the create-only receipt chain and must pass the
  canonical package identity explicitly.
- Failed and superseded generations intentionally consume disk until a
  separately proven maintenance/uninstall reclamation path runs.

## Commit

- `fix: commit lifecycle through immutable generations` (this Task 2 commit)

## Fix round 1 — complete the real generation-bootstrap lifecycle

### Review status and RED evidence

The scoped review of `e80b829..2101485` failed with one Critical and six
Important findings. This round keeps `2101485` and remediates all seven.

- Bootstrap command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1`
  exited `1`; the new real generation-bootstrap case expected exit `0` but
  received `1` because production still required root `active.json`.
- RuntimeManifest command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1`
  exited `1` at the canonical identity assertion because production still
  emitted `projectVersion-digest16` without a nonce.
- The lifecycle review regressions then exposed: transaction-root callbacks
  executing in the wrong module session, a sealed-source fixture failing
  before generation creation, missing upgrade baselines, cross-root state/UI
  writes, global nonterminal state accepted at the real entry, freshly read old
  manifest hashes used for compensation, and contradictory Failed evidence
  after a visible Ready receipt.
- The first aggregate attempt exited `1` at
  `StaticProbeWorker.SelfTest.ps1` with `CCOD_STATIC_RUNTIME_UNAUTHORIZED`;
  that independent runtime authorizer still used the old ID and legacy-only
  selector. The second aggregate attempt exited `1` at
  `UiPreferences.SelfTest.ps1` because the upgrade baseline path had
  accidentally changed the public duplicate-initialize contract.

### GREEN and verification evidence

- Bootstrap: `24/24`, exit `0`. Coverage includes a copied generation
  bootstrap actually launching its selected Supervisor with no `active.json`,
  append-only selector unknown/reparse/ADS/multilink rejection, and legacy
  fallback only when the chain is absent.
- InstallLifecycle: `114/114`, exit `0`. Coverage includes same-generation
  bootstrap parent readiness, legacy-root parent rejection under append-only
  selection, global pointer-less/ambiguous transaction exclusion, fresh and
  upgrade baselines, cross-root rejection, partial operational state,
  recorded-old-manifest compensation, and the Ready final-snapshot gap.
- RuntimeManifest: 18 named cases, exit `0`, including canonical
  `projectVersion-fileDigest16-nonce32`, copied/renamed identity with recorded
  manifest hash, wrong nonce/content, and selector ADS/multilink checks.
- UninstallBootstrap: `13/13`, exit `0`, including canonical-ID and
  append-only generation-7 authorization without legacy `active.json`.
- PersistenceIO: 24 named cases, exit `0`.
- StaticProbeWorker: 37 named cases, exit `0`, including append-only runtime
  authorization without legacy `active.json`.
- UiPreferences focused suite: 9 cases, exit `0`; the default duplicate
  initialize behavior remains `CCOD_UI_PREFERENCES_EXISTS`, while only the
  root-bound lifecycle path opts into reading an existing upgrade baseline.
- Parser: explicit `ParseFile` checks passed for all 12 changed PowerShell
  code/test files.
- Diff: `git diff --check` exited `0`; only LF-to-CRLF checkout warnings were
  emitted.
- Aggregate:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
  exited `0` (`FIX1_AGGREGATE_FINAL_EXIT=0`).

### Remediated behavior

- The generation bootstrap and every audited runtime authorizer read a strict,
  contiguous append-only active-generation chain first and use legacy
  `active.json` only when that chain is absent.
- Runtime identity is exactly
  `projectVersion-fileDigest16-nonce32`; RuntimeManifest, bootstrap,
  StaticProbeWorker, and UninstallBootstrap independently recompute it from
  sorted file records.
- The install entry rejects any global nonterminal or ambiguous transaction
  before creating a generation, independent of pointer/package identity.
- Every fresh or upgrade generation records all five immutable initialization
  baselines. Complete operational state is snapshotted but not overwritten;
  partial/malformed operational state fails closed.
- StateStore and UiPreferences no longer accept file-transaction capabilities.
  InstallLifecycle first validates the opaque transaction root, then writes
  baselines itself, so root A cannot be combined with StateRoot B.
- Active pointer readers reject unknown objects, reparse points, ADS, and
  multi-linked leaves. Transaction records bind both old and new manifest
  SHA-256 values; compensation uses only the recorded old hash.
- A final transaction-snapshot failure after a visible Ready activation receipt
  returns `CCOD_INSTALL_READY_FINALIZATION_PENDING`, leaves the transaction at
  `ProtectionReady`, and writes no contradictory Failed receipt or snapshot.

### Fix commit

- `fix: complete generation bootstrap lifecycle` (this fix-round commit)
