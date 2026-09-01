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

## Fix round 2 — recover append-only lifecycle finalization

### RED and root-cause evidence

- The pre-recovery lifecycle baseline command
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `0` with `Install lifecycle self-tests passed: 114`; this proved the
  existing suite covered only creation of the `ProtectionReady` gap, not a
  later invocation that completes it.
- After adding the second-invocation recovery regression, the same command
  exited `1` with
  `CCOD_SELFTEST_FAILED case=a-later-invocation-recovers-one-missing-Ready-transaction-snapshot-without-another-install-mutation error=CCOD_INSTALL_SOURCE_MISSING`.
  The real entry touched the vanished source checkout before attempting any
  state-only recovery.
- The first implementation run exited `1` with
  `CCOD_INSTALL_READY_RECOVERY_INVALID`; temporary bounded diagnostics traced
  that failure to calling the private, non-exported
  `Get-CcodRuntimeDirectoryForId`. The final implementation derives the
  already validated runtime path locally and applies the existing contained
  install-path proof; the temporary diagnostic text was removed.

### GREEN and final verification evidence

- InstallFileTransaction command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
  exited `0`; all 26 named cases passed. Coverage includes V4 state-only
  create-only records, duplicate-record rejection, generation/payload/
  manifest/retained/pointer/retirement exclusion, and a forced re-import with
  the V3 marker already present.
- InstallLifecycle command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `0` with `Install lifecycle self-tests passed: 116`. A later
  invocation with the source checkout removed appends exactly one matching
  Ready transaction snapshot and creates no runtime, pointer, task start, or
  Failed record. Malformed Ready receipt, mismatched append-only pointer, and
  changed manifest bytes each remain `ProtectionReady` and write nothing.
- Bootstrap exited `0` with `Bootstrap self-test passed: 24`.
- RuntimeManifest exited `0`; all 19 named cases reported `True`, including
  real default-adapter fresh and append-only upgrade pointer commits.
- StaticProbeWorker exited `0`; all 38 named cases reported `True`, including
  unsafe selector root/leaf/JSON/generation rejection.
- UninstallBootstrap exited `0` with
  `Uninstall bootstrap self-tests passed: 14`.
- PersistenceIO exited `0`; all 24 named cases reported `True`.
- UiPreferences exited `0`; all 9 named cases reported `PASS`.
- Explicit PowerShell parser checks passed for all 12 changed `.ps1`/`.psm1`
  files (`PARSER_COUNT=12`).
- `git diff --check` exited `0`; it emitted only checkout LF-to-CRLF warnings.
- Aggregate command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
  exited `0`; after expanding the forced-V3-reimport denial matrix, the final
  aggregate rerun also exited `0`. Both aggregate runs emitted no stdout/stderr
  result text.

### Recovered behavior and boundaries

- `Open-CcodInstallStateTransaction` is ABI V4 and can traverse only
  root-to-`state` directories and publish create-only state records. It cannot
  create/open/mutate a generation, copy payload bytes, write a generation
  manifest, select a retained generation, commit an active pointer, or retire
  a generation.
- `Invoke-CcodInstall` distinguishes only the exact recoverable
  `ProtectionReady` head from other nonterminal transactions. It revalidates
  immutable transaction identity, the exact append-only active runtime and
  generation, the recorded new-manifest SHA-256, the current runtime manifest,
  and exactly one matching Ready activation receipt before and after opening
  the state-only capability.
- Recovery occurs before source validation and performs no install, task,
  process, pointer, log, activation-receipt, or Failed write. A proof mismatch
  returns `CCOD_INSTALL_READY_RECOVERY_INVALID`; a state-only append failure
  remains retryable as `CCOD_INSTALL_READY_FINALIZATION_PENDING`.
- Selector readers in Bootstrap, StaticProbeWorker, and UninstallBootstrap
  reject a non-directory selector root and unsafe, malformed, duplicate,
  non-integral, or noncanonical leaves. Legacy `active.json` fallback remains
  available only when the append-only root is absent.
- No push, tag, release, build, installation, product-process action,
  WindowsApps access, DPAPI access, or external write was performed.

### Remaining concerns

- The documented current-user ordinary-race boundary is unchanged; this is not
  a sandbox against unrestricted same-user or in-process code.
- Failed and superseded immutable generations remain retained until the
  separately proven reclamation path runs.

## Fix round 3 — fail closed selector fallback

### RED and root-cause evidence

- RuntimeManifest command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1`
  exited `1` at
  `default-immutable-fence-rejects-selector-root-files-and-non-not-found-lookup-failures-before-pointer-commit`
  with `CCOD_INSTALL_POINTER_COMMIT_FAILED` and `The directory name is
  invalid`. A selector-root file passed the authorization read and failed only
  later inside pointer commit.
- Bootstrap command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1`
  exited `1` at
  `bootstrap-selector-fallback-requires-proven-ItemNotFound-instead-of-a-lookup-error`;
  the wished-for selector lookup seam did not yet exist
  (`NamedParameterNotFound,Read-CcodBootstrapActivePointer`).
- StaticProbeWorker command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\StaticProbeWorker.SelfTest.ps1`
  exited `1` in the hostile selector matrix with
  `ASSERT_THROWS: expected CCOD_STATIC_RUNTIME_UNAUTHORIZED`. The exact
  identified case was `schema`: selector `schemaVersion:2` was authorized.
- UninstallBootstrap command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1`
  exited `1` at
  `uninstall-selector-fallback-requires-proven-ItemNotFound-instead-of-a-lookup-error`;
  the wished-for selector lookup seam did not yet exist
  (`NamedParameterNotFound,Get-CcodUninstallBootstrapVerifiedRuntimeContext`).

### GREEN and final verification evidence

- InstallFileTransaction exited `0`; all 26 named cases passed. The V3/V4
  evidence now uses a fresh child `powershell.exe`: V3 is defined first, V4 is
  proven absent before import, the current module then exposes ABI V4, one
  state record is appended, and generation leaf, copy, manifest, retained,
  pointer, and retirement operations are rejected through exports only.
- Bootstrap exited `0` with `Bootstrap self-test passed: 25`.
- RuntimeManifest exited `0`; all 20 named cases reported `True`.
- StaticProbeWorker exited `0`; all 39 named cases reported `True`.
- UninstallBootstrap exited `0` with
  `Uninstall bootstrap self-tests passed: 15`.
- InstallLifecycle exited `0` with
  `Install lifecycle self-tests passed: 116`.
- PersistenceIO exited `0`; all 24 named cases reported `True`.
- UiPreferences exited `0`; all 9 named cases reported `PASS`.
- Explicit parser checks passed all 9 changed `.ps1`/`.psm1` files
  (`PARSER_COUNT=9`).
- `git diff --check` exited `0`; it emitted only checkout LF-to-CRLF warnings.
- Aggregate command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
  exited `0` and emitted no stdout/stderr result text.

### Behavior and boundaries

- RuntimeManifest/default fence, Bootstrap, StaticProbeWorker, and
  UninstallBootstrap permit legacy `active.json` fallback only after a proven
  ItemNotFound result for `state\active-generation`. Root files, reparse
  points, access/I/O lookup errors, null/non-proof adapter returns, malformed
  stores, and unsupported records fail with the component's bounded pointer or
  runtime authorization error.
- StaticProbeWorker now requires append-only selector `schemaVersion` to be
  exactly integer `1`. Static and Uninstall matrices cover malformed JSON,
  unsupported schema, duplicate key, ADS, multi-link, root/leaf reparse,
  fractional generation, and noncanonical names before runtime authorization.
  Bootstrap retains equivalent hostile-selector coverage.
- Every fix2 invariant remains covered, including the real default pointer
  fence, state-only Ready finalization, recorded-manifest compensation, and no
  root-shell overwrite.
- No push, tag, release, build, installation, product-process action,
  WindowsApps access, DPAPI access, or external write was performed.

### Remaining concerns

- The documented current-user ordinary-race boundary remains unchanged.
- Failed and superseded immutable generations remain retained until the
  separately proven reclamation path runs.

## Fix round 4 — prove selector absence safely

### RED and root-cause evidence

- RuntimeManifest exited `1` at
  `legacy-fallback-rejects-a-state-ancestor-file-before-active-runtime-authorization`
  with `ASSERT_THROWS: expected CCOD_RUNTIME_POINTER_INVALID`. A valid legacy
  pointer was accepted when the intermediate `state` object was a regular file.
- Bootstrap exited `1` at
  `bootstrap-legacy-fallback-rejects-a-state-ancestor-file` with
  `ASSERT_THROWS: expected CCOD_BOOTSTRAP_POINTER_INVALID`; the child lookup's
  ItemNotFound result hid the invalid parent object.
- StaticProbeWorker exited `1` at
  `selector-lookup-requires-an-explicit-discriminated-absence-proof` with
  `CCOD_STATIC_RUNTIME_UNAUTHORIZED`: an actual ItemNotFound adapter result was
  collapsed into generic adapter failure. After the discriminated lookup was
  added, the next RED run reached
  `legacy-authorization-rejects-a-state-ancestor-file` and exited `1` with
  `ASSERT_THROWS`, proving that the parent check remained independently absent.
- UninstallBootstrap exited `1` at
  `uninstall-legacy-fallback-rejects-a-state-ancestor-file-at-the-selector-boundary`
  with `ASSERT_TRUE`; it did not reject the malformed parent at the bounded
  selector authorization boundary.

### GREEN and final verification evidence

- InstallFileTransaction exited `0`; all 26 named cases passed, including the
  V4 state-only no-escape and V3-first re-import evidence.
- Bootstrap exited `0` with `Bootstrap self-test passed: 26`.
- RuntimeManifest exited `0`; all 21 named cases reported `True`.
- StaticProbeWorker exited `0`; all 41 named cases reported `True`, including
  actual ItemNotFound fallback, null/empty/malformed/unknown result rejection,
  and the `state`-file boundary.
- UninstallBootstrap exited `0` with
  `Uninstall bootstrap self-tests passed: 16`.
- InstallLifecycle exited `0` with
  `Install lifecycle self-tests passed: 116`.
- PersistenceIO exited `0`; all 24 named cases reported `True`.
- UiPreferences exited `0`; all 9 named cases reported `PASS`.
- Explicit PowerShell parser checks passed all 8 changed `.ps1`/`.psm1` files
  (`PARSER_COUNT=8`).
- `git diff --check` exited `0`; it emitted only checkout LF-to-CRLF warnings.
- Aggregate command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
  exited `0` and emitted no suite failure text.

### Behavior and boundaries

- RuntimeManifest/default fence, Bootstrap, StaticProbeWorker, and
  UninstallBootstrap now consult legacy `active.json` only when `state` itself
  has an exact ItemNotFound outcome, or when `state` is a proven plain
  nonreparse directory and `state\active-generation` has an exact ItemNotFound
  outcome. A parent file, reparse point, inaccessible object, lookup failure,
  or other non-directory fails the component's bounded authorization contract.
- StaticProbe selector lookup now returns one exact discriminated
  `{ Status, Item }` object. Only `Status='Missing'` with a null item, produced
  from an exact ItemNotFound exception, represents absence; `Found` requires a
  nonnull item, and null, empty, malformed, unknown, diagnostic, or exceptional
  adapter results fail before runtime import.
- Every earlier Task 2 invariant remains covered, including V4 state-only
  recovery containment, append-only Ready finalization, canonical runtime
  identity, the real default pointer fence, recorded-manifest compensation,
  strict selector leaf validation, and no root-shell overwrite.
- No push, tag, release, build, installation, product-process action,
  WindowsApps access, DPAPI access, or external write was performed.

### Remaining concerns

- The documented current-user ordinary-race boundary remains unchanged.
- Failed and superseded immutable generations remain retained until the
  separately proven reclamation path runs.
