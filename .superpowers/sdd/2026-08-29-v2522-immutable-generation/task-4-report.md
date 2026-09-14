# Task 4 report: post-Ready product registration

## Status

Implemented current-user uninstall registration and the exact Start-menu and
desktop `CodexRemote-fix.lnk` records after the Task 2 terminal `Ready` proof.
All three new records are read back before the exact legacy migration is
authorized. Product-registration failures are reported after the file
transaction closes and never enter install compensation, append `Failed`, or
downgrade an already durable `Ready` transaction.

The direct installed uninstaller now runs only from the canonical selected
`2.5.22-<digest16>-<nonce32>` generation, invokes that generation's
manifest-bound uninstall bootstrap, and completes through the verified
external transaction payload. No Inno uninstaller is required.

No real registry or shortcut mutation, installer/uninstaller/product
execution, release build, network write, push, tag, signing, or publication was
performed.

## RED evidence

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1`
  exited `1` because
  `src\persistence\modules\ProductRegistration.psm1` did not exist.
- After the six registration behavior groups were added, the lifecycle suite
  exited `1` with `CCOD_INSTALL_ADAPTER_INVALID`, target
  `RegisterProduct`; there was no post-Ready lifecycle seam.
- The uninstall bootstrap suite exited `1` with
  `CCOD_UNINSTALL_ADAPTER_INVALID`, target `RemoveProductRegistration`; there
  was no verified post-cleanup product-state remover.
- The file-transaction suite exited `1` because the exact capability export
  surface did not contain the fixed SpecialFolder open/copy operations.
- The Ready-finalization recovery regression exited `1`: expected one product
  registration after the missing Ready snapshot was recovered, actual zero.

## GREEN evidence

- Product registration:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1`
  exited `0`; `Product registration self-tests passed: 6`.
- File capability:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
  exited `0`; all 26 named cases passed.
- Uninstall bootstrap:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1`
  exited `0`; `Uninstall bootstrap self-tests passed: 17`.
- Install lifecycle:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `0`; `Install lifecycle self-tests passed: 115`.
- Explicit PowerShell parser checks passed all nine changed `.ps1`/`.psm1`
  implementation and test files (`PARSER_FAILURES=0`).
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were
  emitted.
- The aggregate `tests\PersistenceSelfTest.ps1` was not requested by the Task
  4 brief and was not run; no aggregate-pass claim is made.

## Implemented boundaries

- `New-CcodProductRegistration`, `Test-CcodProductRegistration`,
  `Commit-CcodProductRegistration`, and
  `Remove-CcodLegacyProductRegistration` enforce the canonical runtime ID,
  exact version/hash, exact runtime bootstrap/uninstaller paths, fixed HKCU
  product key, and two fixed shortcut leaves.
- Shortcut candidates are generated before runtime identity calculation,
  copied into `registration/` inside the immutable generation, included in its
  manifest/runtime-ID binding, and copied after Ready only through pinned
  current-user Programs/Desktop handles. Arbitrary destination paths and
  shortcut leaf names are not accepted.
- The shortcut candidates start the one fixed current-user Supervisor task.
  Task 2 already binds that task action to the selected generation bootstrap;
  this avoids embedding a not-yet-computable runtime ID in candidate bytes
  while still resolving the sealed bootstrap selected and proven Ready.
- Normal install and the bounded missing-Ready-snapshot recovery both perform
  post-Ready registration. The recovery uses the state transaction only for
  fixed SpecialFolder capability operations; generation and pointer mutation
  remain unavailable.
- Uninstall removes only a matching current product runtime key and the two
  exact new shortcut paths after protected application cleanup. Legacy
  migration requires the canonical AppId, verified new registration, and the
  exact legacy shortcut allowlist before deletion starts.

## Compatibility concerns

- Legacy migration is deliberately conservative: a missing or changed legacy
  shortcut name, wrong AppId, or unreadable legacy entry retains all legacy
  state for later diagnosis rather than attempting partial cleanup.
- The ordinary same-user writer and in-process introspection limits documented
  by the immutable-generation design remain unchanged.
- No live Windows Settings launch, real shell-link promotion, or installed
  uninstall was executed in this task; those remain part of later installed
  acceptance.

## Implementation commit

- `e43d9ce18c5d79bb438e08c9ff2973be592277aa`
  (`feat: register product only after readiness`).

## Fix round 1: matched uninstall and retriable registration

Scoped review of `70bc231..97cf17d` found one Critical and four Important
issues. The installed wrapper could synchronously continue after deleting its
own generation; product cleanup could remove an entire key without exact
value/shortcut evidence; `AlreadyInstalled` skipped registration retry;
legacy removal was not compensating; and shortcut copy accepted a state-only
transaction plus arbitrary absolute source path.

### RED evidence

- UninstallBootstrap first exited `1` because
  `src\persistence\InstalledUninstallFinalizer.ps1` did not exist.
- ProductRegistration exited `1` with `CCOD_PRODUCT_ADAPTER_INVALID`, target
  `ReadLegacyEntry`, before exact current-state and per-entry legacy
  compensation adapters existed.
- InstallLifecycle exited `1` in the exact Ready/package idempotence case:
  registration calls expected `1`, actual `0`.
- InstallFileTransaction exited `1` because the export surface lacked
  `Open-CcodInstallProductRegistrationTransaction` and
  `Open-CcodInstallRetainedFile`; product shortcut copy still exposed
  `SourcePath`.

### GREEN and verification evidence

- ProductRegistration exited `0` with
  `Product registration self-tests passed: 9`. Coverage includes exact
  registry/shortcut evidence, unknown/replaced/reparse/ambiguous no-delete,
  mid-sequence legacy restoration, and replacement-preserving compensation.
- InstallFileTransaction exited `0`; all 27 named cases passed. The new case
  proves product-only retained-file authority, no arbitrary shortcut source
  path, state-only denial, and product-scope denial for state writes.
- UninstallBootstrap exited `0` with
  `Uninstall bootstrap self-tests passed: 19`. The installed path now stops at
  `TaskRemoved`; its staged finalizer waits for exact wrapper exit, validates
  transaction and selected generation, performs matched removal, proves root
  absence, removes only matched product state, and then finalizes. Wrong
  wrapper/generation/transaction cases delete nothing.
- InstallLifecycle exited `0` with
  `Install lifecycle self-tests passed: 116`. Both normal and missing-Ready
  recovery registration failures remain outside rollback/Failed and are
  reconciled by a later exact same-package `AlreadyInstalled` invocation.
- Explicit parser checks passed all 11 changed PowerShell source/test files
  (`PARSER_COUNT=11`, `FAILURES=0`).
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were
  emitted.
- The aggregate `tests\PersistenceSelfTest.ps1` was not run in this fix round;
  no aggregate-pass claim is made.

### Remediated boundaries

- The selected-generation wrapper launches a hidden external finalizer from
  the ACL-bound staged payload and returns. Application removal cannot begin
  until the exact wrapper PID/creation-time identity has exited.
- Current product cleanup accepts only the exact allowed registry value names,
  kinds and values plus both shortcut hashes, targets, arguments, and regular
  file identities. Registry values are revalidated and removed individually;
  a key is deleted only after it is empty and has no subkeys.
- Legacy migration captures exact registry kinds/values and shortcut bytes,
  deletes entries one by one, and restores prior removals in reverse order
  only while their names remain absent. A replacement is never overwritten.
- Product shortcut promotion now accepts only an opaque file capability opened
  from one selected generation at either fixed manifest-relative candidate.
  Product-only transactions cannot write state, generations, manifests,
  pointers, or retirements; state-only transactions cannot acquire shortcut
  authority.

### Compatibility and external boundaries

- Conservative mismatch behavior may leave current or legacy registration for
  diagnosis instead of partially deleting it.
- No real registry, shortcut, installer, uninstaller, product process,
  WindowsApps, DPAPI, network, release, push, tag, signing, or publication
  action was performed.

### Fix implementation commit

- `2e76698d535e6e824df1c57d81314be1c2e053e8`
  (`fix: complete matched product lifecycle`).

## Fix round 2: exact Ready-bound finalization and cleanup

Scoped review of `97cf17d..0fdc392` found four Important gaps: installed
finalization did not durably bind wrapper/manifest/epoch and removed too broad
a root; coherent registration replacement could self-authorize cleanup;
product source authority did not require latest selected Ready evidence; and
legacy restore failures were suppressed.

### RED evidence

- UninstallBootstrap exited `1` with `CCOD_INSTALLED_FINALIZER_INVALID`, target
  `RemoveSelectedGeneration`, then separately with `NamedParameterNotFound`
  for `Invoke-CcodUninstallBootstrap -WrapperIdentity`.
- ProductRegistration exited `1` because `Remove-CcodProductRegistration`
  lacked `ReadyEvidence`; the fixed `schtasks.exe` negative later failed by not
  throwing `CCOD_PRODUCT_REGISTRATION_NOT_READY`.
- InstallFileTransaction exited `1` because
  `Open-CcodInstallProductRegistrationTransaction` lacked `ReadyEvidence`.
- ProductRegistration exited `1` with `CCOD_PRODUCT_ADAPTER_INVALID`, target
  `WriteLegacyCompensationFailure`.

### GREEN evidence

- ProductRegistration: `10/10`, exit `0`.
- InstallFileTransaction: `27/27`, exit `0`.
- UninstallBootstrap: `19/19`, exit `0`.
- InstallLifecycle: `116/116`, exit `0`.
- Explicit parser checks: `10/10`, zero failures.
- `git diff --check`: exit `0`; only LF-to-CRLF checkout warnings.
- Aggregate was not run; no aggregate-pass claim is made.

### Boundaries

- Prepare durably records exact wrapper PID/creation/session/SID, selected
  runtime root, manifest hash, generation, Ready evidence and lease epoch.
  Finalizer requires an initially verified wrapper and its later exact exit,
  current epoch, matching leaf/manifest, and deletes only that generation.
- Registration and cleanup bind canonical install root, Ready runtime and
  generation, package/manifest/candidate hashes, exact arguments, and the
  canonical `%System%\schtasks.exe` target. Coherent arbitrary replacements
  preserve every entry.
- Product-only and retained-file capabilities require the latest append-only
  pointer, matching manifest and one matching Ready install record; pre-Ready,
  stale/unselected, absolute, state-only and wrong-relative sources fail.
- Legacy compensation verifies absence before each restore. Replacement or
  restore failure is never overwritten or swallowed: it writes an explicit
  unresolved record and returns `CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED`.
  A normal migration failure is reported only after full restoration.

No real registry, shortcut, uninstall, product process, WindowsApps, DPAPI,
network, release, push, tag, signing, or publication action was performed.

### Fix implementation commit

- `283ecbe3eb012f1e78377e9336aacc7b3acc9336`
  (`fix: bind matched product finalization`).

### Supplemental pre-cleanup target gate

Final pre-commit audit added a noncanonical Ready target negative. Its RED
returned the expected validation error but observed `Cleanup=1`: validation
failure was captured without clearing the fresh context. The fix clears every
failed fresh context, validates the same canonical Ready invariant on stored
resume transactions, and rejects before cleanup. Fresh UninstallBootstrap is
`20/20`, exit `0`; focused parser `4/4` and diff check exit `0`.

- Supplemental commit: `67c79d82e18c805f27aec8e05553938f1f706380`
  (`fix: reject invalid Ready evidence before cleanup`).

## Fix round 3: strict retained authority and default finalizer proof

Independent review found five Important gaps in stored Ready validation,
retained authority, current-state preflight, the current partially removed
legacy entry, and mock-only finalizer coverage.

### RED evidence

- Stored noncanonical Ready target returned the expected error but observed
  `Cleanup=1`; failed fresh validation retained its context.
- Product authority accepted a fabricated five-field Ready object and did not
  bind non-derived fields such as `oldRuntimeId`.
- Current product inspection did not reject an unknown registry subkey before
  returning deletable entries.
- A partially mutated current Registry entry was absent from the outer
  unresolved compensation set.
- Installed finalizer tests replaced all five filesystem/identity boundaries
  rather than exercising their defaults.

### GREEN evidence

- ProductRegistration: `11/11`, exit `0`.
- InstallFileTransaction: `27/27`, exit `0`.
- UninstallBootstrap: `21/21`, exit `0`.
- InstallLifecycle: `116/116`, exit `0`.
- Full `tests\PersistenceSelfTest.ps1` aggregate: exit `0` after about
  7 minutes 15 seconds; it emitted no failure output.
- Parser: `8/8`, zero failures. `git diff --check`: exit `0`.

### Remediated boundaries

- Product authority accepts the complete ordered 12-field lifecycle Ready
  record. The product capability stores its canonical complete identity; each
  retained-file open compares the caller's complete record, including
  `oldRuntimeId`, then rechecks the latest append-only selector and unique
  strict Ready record.
- Current cleanup rejects registry subkeys before returning any entry.
- Legacy compensation includes the entry whose removal itself failed; partial
  Registry restore failure is recorded unresolved and cannot be reported as a
  fully restored migration failure.
- A disposable default finalizer fixture preserves the production transaction
  reader, selected-generation/manifest validator, epoch reader, selected-root
  remover, and absence proof. Only wrapper wait, product registry cleanup and
  receipt finalization are replaced. It deletes the selected runtime while
  preserving sibling install state.
- Normal/recovery registration retry and durable Ready preservation remain
  green. No real registry, shortcut, uninstall, product, network, release,
  signing, tag, push, or publication action occurred.

### Implementation commit

- `1ff17bb8759e3d5312c11336ca3b2188bb3a4fe2`
  (`fix: enforce strict retained product authority`).

## Fix round 4: durable Ready identity and real finalizer negatives

Independent review of `7c333e0..a83840b` found five Important gaps: fresh and
stored uninstall paths did not share one current-root Ready invariant; product
authority still reduced a strict lifecycle record to five fields and did not
prove a complete selector/store at every retained-file open; legacy/current
registry negatives were adapter-shaped rather than production comparisons; and
the installed-finalizer evidence covered only a safe adapter-assisted positive.

### RED evidence

- UninstallBootstrap exited `1` in
  `fresh and stored Ready evidence require one exact current-install-root
  invariant before cleanup`: a fresh rooted but unrelated `installRoot` was
  accepted instead of throwing `CCOD_UNINSTALL_BOOTSTRAP_INVALID`. The same
  case also covers stored `TaskRemoved` wrong-root and extra-field records with
  an explicit zero-cleanup assertion.
- InstallFileTransaction exited `1` with
  `ASSERT_THROWS: expected CCOD_INSTALL_PRODUCT_SCOPE`: capability open first
  accepted a caller record whose `oldRuntimeId` differed while all five derived
  fields matched. The completed matrix also covers transaction ID/owned-set
  mismatch, a fabricated five-field object, pointer gap/unexpected directory,
  a stale N capability after N+1, changed persisted Ready identity, and a
  scalar `ownedObjectNames` value.
- ProductRegistration exited `1` because the production-private
  `Test-CcodCurrentProductRegistryPreflight` did not exist. The regression calls
  that same helper with an unexpected subkey and proves zero removals.
- ProductRegistration exited `1` because the production-private
  `Compare-CcodLegacySnapshotEntry` did not exist. Its fixture keeps the
  Registry key present while removing one captured value; the result must be
  `Mismatch`, the unresolved create-only record must contain `Registry`, and
  the stable error must be `CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED`.
- The first no-adapter staged-finalizer child matrix exited `1` instead of the
  stable `3`: `Write-Error` re-threw under the script's Stop preference. After
  that was fixed, the wrong stored Ready root reached selected-generation
  deletion, exposing a dot-sourced `$InstallRoot` parameter collision in the
  default transaction reader. Both failures occurred before the final GREEN.
- InstallFileTransaction exited `1` with
  `ASSERT_THROWS: expected CCOD_INSTALL_PRODUCT_SCOPE` after hard-linked
  pointer, transaction, and manifest leaves were added; the first hard-linked
  authority leaf was accepted.
- InstallFileTransaction exited `1` because the production-private
  `Read-CcodInstallAuthorityFile` did not exist. The wished-for contract returns
  bytes and SHA-256 from one verified native handle and rejects a multi-link.

### GREEN and final verification evidence

- ProductRegistration: `13/13`, exit `0`.
- InstallFileTransaction: `29/29`, exit `0`.
- UninstallBootstrap: `23/23`, exit `0`. The no-adapter child matrix stages the
  real `InstalledUninstallFinalizer.ps1` below a fake process `LOCALAPPDATA` and
  covers same-bootstrap sibling, wrong runtime path, stale epoch, wrapper
  PID/creation mismatch, wrong stored Ready root, and an extra Ready field.
  Every case preserves the selected generation and sibling/root state; cases
  beyond the early path/identity gates also prove the disposable wrapper exited.
- InstallLifecycle: `116/116`, exit `0`, preserving normal/recovery registration
  retry and durable Ready behavior.
- Explicit PowerShell parser: `8/8`, `PARSER_FAILURES=0`, exit `0`.
- Static gates: `WEAK_SUBSTITUTE_COUNT=0` and
  `AUTHORITY_PATH_READ_COUNT=0`, exit `0`; the default finalizer reader receives
  and forwards `ExpectedInstallRoot`.
- `git diff --check`: exit `0`; only checkout LF-to-CRLF warnings were emitted.
- Full `tests\PersistenceSelfTest.ps1` aggregate: exit `0`; no failure output.
- Final independent scoped re-review found no remaining Critical or Important
  findings.

### Remediated boundaries

- One ordered ten-field Ready helper validates fresh contexts, durable stored
  transactions/resume, and default finalizer authorization against the exact
  current install root before selected-root deletion.
- Product capability open validates the ordered/type-strict 12-field lifecycle
  record, complete canonical contiguous selector, all canonical transaction
  chains, the unique full persisted terminal Ready record, and the selected
  manifest/package identity. Every retained-file open repeats that proof and
  compares caller, persisted, and stored capability identities.
- Selector JSON, lifecycle JSON, and manifest hashes are read from one native
  no-write/no-delete-share handle. The handle rejects reparse, ADS and
  multi-link leaves, checks final path and file identity before and after the
  read, and hashes the returned bytes rather than reopening by path.
- Current-product subkeys fail a production pure preflight before shortcut
  inspection. Legacy Registry compensation distinguishes exact, absent, and
  mismatched key/value/kind snapshots; a partial key is never called restored
  or overwritten.
- The installed finalizer accepts only a canonical absolute process
  `LOCALAPPDATA` when it is present, otherwise falls back to the current-user
  special folder. The staged default reader carries the expected install root
  through dot-sourcing without a parameter-name collision.

No real registry, shortcut, installer, uninstaller, product, network, release,
signing, tag, push, or publication action occurred.

### Fix implementation commit

- `3cd891221acfd569fd29e2244b5200fa28e43106`
  (`fix: prove durable Ready product authority`).

## Fix round 5: canonical lifecycle authority, proof-to-use lease, and first-install handoff

Independent review of `a83840b..a60759b` found three Important production
gaps: product authority maintained a weaker parallel transaction-chain reader;
selector proof and retained-file use were not serialized against an N+1
commit; and normal first install passed its still-writable generation
transaction to the default product-registration path.

This was the fifth and final permitted Task 4 repair round. The implementation
below is submitted for a new independent review; Task 4 is not claimed complete.

### RED evidence

- InstallFileTransaction exited `1` because a selected terminal Ready chain
  plus an unrelated strict Prepared head was accepted instead of throwing
  `CCOD_INSTALL_PRODUCT_SCOPE`. The companion Ready-to-Failed continuation
  regression was added to the same canonical-head boundary.
- The real two-process coordination regression reached
  `Enter-CcodLifecycleOwnership` and `Set-CcodActiveRuntime` for N+1 while an N
  product transaction was active. Before the lease fix, N+1 committed and the
  subsequent N retained-file use failed with `CCOD_INSTALL_PRODUCT_SCOPE`;
  proof and use were not one stable authority operation.
- Clearing only the product transaction's stored authority-lease state while
  retaining the real mutex still allowed a retained-file open; the test exited
  `1` with `ASSERT_THROWS: expected CCOD_INSTALL_PRODUCT_SCOPE`.
- The safe default first-install integration initially failed adapter
  resolution because no lower product-side-effect seam existed. Once only the
  registry/shortcut side effects were isolated, the old path failed with
  `CCOD_PRODUCT_REGISTRATION_FAILED`; a targeted diagnostic recorded
  `CCOD_INSTALL_RETAINED_GENERATION_INVALID` and a sharing violation because
  the writable generation transaction was still pinned after Ready.
- The new post-Ready close-failure case first exited `1` with
  `CCOD_INSTALL_ADAPTER_INVALID`, target `CloseReadyGeneration`, before the
  narrow close handoff existed.

### GREEN and final verification evidence

- InstallFileTransaction: all 32 named cases passed, exit `0`. Coverage includes
  the unrelated Prepared head, Ready-to-Failed continuation, missing live
  authority lease, and a real N/N+1 coordination process pair.
- ProductRegistration: `13/13`, exit `0`.
- UninstallBootstrap: `23/23`, exit `0`.
- InstallLifecycle: `119/119`, exit `0`. The real default registration path
  opens both retained shortcut candidates through product-only authority;
  normal first install succeeds, product-write failure remains durable Ready
  and retries through AlreadyInstalled, and post-Ready writable-close failure
  performs zero product writes, appends no Failed snapshot, and retries.
- Explicit PowerShell parser checks passed all four changed source/test files:
  `PARSER_COUNT=4`, `PARSER_FAILURES=0`.
- Static gates passed: `WEAK_SUBSTITUTE_COUNT=0`,
  `AUTHORITY_PATH_READ_COUNT=0`, `CANONICAL_RESOLVER_CALL_COUNT=1`,
  `WRITABLE_REGISTRATION_SOURCE_COUNT=0`, `STRICT_PRODUCT_OPEN_COUNT=1`, and
  `READY_CLOSE_ADAPTER_CALL_COUNT=2`.
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were emitted.
- Full `tests\PersistenceSelfTest.ps1` aggregate exited `0` with no failure
  output. Its long-running child at the observed midpoint was the existing
  TrayHost production-trace suite, not the new authority/lifecycle tests.

### Remediated boundaries

- InstallLifecycle owns the one canonical pure
  `Resolve-CcodInstallTransactionRecordHead` implementation. Its normal reader
  and InstallFileTransaction's native-handle authority reader both call that
  implementation; product authority no longer carries a reduced parallel
  chain checker. The native-handle selector, manifest, and transaction-file
  reads remain intact, and the canonical record validator now also requires
  `ownedObjectNames` to be an array.
- Product transaction open acquires the same current-user global
  `AccountTransition` mutex used by lifecycle ownership before reading the
  selector. The opaque transaction retains that lease through canonical
  selector/manifest/transaction proof and retained-file opens. Close attempts
  both native cleanup and lease release on failure paths; retained-file open
  explicitly requires the live product-only lease on its owning thread.
- The deterministic N/N+1 test uses the real lifecycle-ownership and active
  pointer commit paths. N+1 blocks while N opens its retained shortcut, commits
  generation 2 only after N closes, and the closed stale N capability cannot
  be reused.
- Normal and recovered Ready paths close their writable generation/state
  transaction before product registration. The default RegisterProduct adapter
  always opens and owns a separate strict selected product transaction; the
  writable input is never used as shortcut authority. A close or registration
  failure is post-Ready, performs no lifecycle rollback, and is reconciled by
  a later same-package invocation.

No real registry, shortcut, installer, uninstaller, product process, network,
release, signing, tag, push, or publication action occurred.

### Fix implementation commit

- `a9900a4b00508f9ed694375ea94a2bfb97437e96`
  (`fix: serialize strict product authority`).

## Fix round 6: durable product-close outcome and atomic lock-wait proof

This architecture-level repair addresses the two remaining product-close and
concurrency-proof gaps. It does not claim Task 4 complete. No real registry,
shortcut, installer, uninstaller, product, network, release, signing, tag,
push, or publication action was performed.

### RED evidence

- The default-registration close regression initially failed with
  `CCOD_INSTALL_ADAPTER_INVALID`: there was no narrow
  `CloseProductTransaction` seam at the owned strict-product-transaction
  boundary. The prior default `RegisterProduct` `finally` also discarded an
  owned transaction close exception and could return a verified receipt.
- The previous N/N+1 test announced a marker before it had reached the real
  `AccountTransition` wait, so it could not prove that the child was actually
  blocked on the same mutex.

### GREEN evidence

- `tests\persistence\InstallFileTransaction.SelfTest.ps1`: exit `0`; all 32
  named cases passed. The N/N+1 case runs the child with `-Mta`, atomically
  signals its real mutex attempt through `SignalAndWait`, proves N can open its
  retained shortcut while the child waits, then proves N+1 commits only after
  N closes and stale N is unusable.
- `tests\persistence\InstallLifecycle.SelfTest.ps1`: exit `0`; `120/120`.
  The new default-path integration forces both the initial owned close and its
  bounded same-thread retry to fail, observes no successful receipt and a
  durable `Ready` record with no `Failed` snapshot, then proves an exact
  same-package reconciliation drains the pending cleanup before opening fresh
  strict product authority and returns verified success.
- `tests\persistence\ProductRegistration.SelfTest.ps1`: exit `0`;
  `13/13`.
- `tests\persistence\UninstallBootstrap.SelfTest.ps1`: exit `0`; `23/23`.
- Explicit PowerShell parser checks on the three changed PowerShell files
  passed with `PARSER_FAILURES=0`. `git diff --check` exited `0`; only
  checkout LF-to-CRLF warnings were emitted.
- A fresh full `tests\PersistenceSelfTest.ps1` aggregate remains pending at
  this evidence point. No aggregate-pass or Task 4 completion claim is made.

### Remediated boundaries

- `CloseProductTransaction` is a narrow lifecycle adapter. The default
  delegates to the normal `Ready` file-transaction close. A first close
  failure always makes the current registration call fail as
  `CCOD_PRODUCT_REGISTRATION_FAILED`, even if its one bounded same-thread
  cleanup retry succeeds; no verified receipt is returned from that call.
- If both close attempts fail, the exact opaque transaction and its bound
  same-module close delegate remain in a synchronized, process-local pending
  table keyed by the canonical install root and owner managed-thread ID. The
  next registration on that same thread drains it before opening fresh product
  authority. A different thread or another cleanup failure fails closed; no
  lease or capability is transferred across threads or processes.
- The normal install, Ready-finalization recovery, and exact
  `AlreadyInstalled` reconciliation all pass the same close adapter to the
  default registration path. The writable generation/state handoff remains
  closed before product registration begins.

### Fix implementation commit

- `2e86de17a7c454cc56edd123b6c6487c5194f32d`
  (`fix: retain failed product transaction cleanup`).
